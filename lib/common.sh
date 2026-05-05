#!/usr/bin/env bash
# common.sh — shared helpers for modules tasks

set -euo pipefail

# The target repo is always CALLER_PWD (set by shiv shim)
TARGET_DIR="${CALLER_PWD:-.}"

# Where modules metadata lives (tracked; manifest encrypted, config plaintext).
MODULES_DIR="$TARGET_DIR/.modules"
MANIFEST="$MODULES_DIR/manifest"
CONFIG="$MODULES_DIR/config"

# Current layout version. Written into .modules/config at setup; read by
# require_initialized to detect incompatible repos (old layout, future
# layout) and produce actionable errors rather than silent misbehavior.
MODULES_LAYOUT_VERSION="0.9.0"

# Paths tracked in git-relative form (for hooks / diff matching).
MANIFEST_REL=".modules/manifest"
CONFIG_REL=".modules/config"

# Default clone-root path (relative to repo root) if no config is set.
DEFAULT_CLONES_PATH="modules"

# Resolve the relative path (from repo root) where module clones live.
clones_path_rel() {
  if [ -f "$CONFIG" ] && command -v jq &>/dev/null; then
    local configured
    if ! configured="$(jq -r '.path // empty' "$CONFIG" 2>/dev/null)"; then
      echo "Error: $CONFIG is not valid JSON" >&2
      exit 1
    fi
    if [ -n "$configured" ]; then
      echo "$configured"
      return
    fi
  fi
  echo "$DEFAULT_CLONES_PATH"
}

# Absolute path to the clone root.
clones_dir() {
  echo "$TARGET_DIR/$(clones_path_rel)"
}

# ── Require checks ────────────────────────────────────────────

require_git() {
  if ! git -C "$TARGET_DIR" rev-parse --git-dir &>/dev/null; then
    echo "Error: not a git repository: $TARGET_DIR" >&2
    exit 1
  fi
}

require_initialized() {
  # Detect pre-v0.9.0 layout (tracked 'submodules/.manifest', JSON format).
  # Give the user an actionable migration pointer instead of a generic
  # 'not initialized' error that would invite them to run `modules setup`
  # and create a parallel .modules/ directory alongside the old layout.
  if [ ! -f "$MANIFEST" ] && [ -f "$TARGET_DIR/submodules/.manifest" ]; then
    echo "Error: this repo uses the pre-v0.9.0 modules layout ('submodules/.manifest')." >&2
    echo "Migration guide: https://github.com/KnickKnackLabs/modules/issues/16" >&2
    echo "(or see den/notes/modules-opacity-migration.md)" >&2
    exit 1
  fi

  if [ ! -f "$MANIFEST" ]; then
    echo "Error: modules not initialized. Run: modules setup" >&2
    exit 1
  fi

  # Version check: if config declares a layout version we don't recognize,
  # refuse rather than risk silent misbehavior.
  if [ -f "$CONFIG" ] && command -v jq &>/dev/null; then
    local declared
    if ! declared="$(jq -r '.version // empty' "$CONFIG" 2>/dev/null)"; then
      echo "Error: $CONFIG is not valid JSON" >&2
      exit 1
    fi
    if [ -n "$declared" ] && [ "$declared" != "$MODULES_LAYOUT_VERSION" ]; then
      echo "Error: this repo declares modules layout version '$declared', but this client supports '$MODULES_LAYOUT_VERSION'." >&2
      echo "Upgrade or downgrade the modules client to match." >&2
      exit 1
    fi
  fi
}

require_jq() {
  if ! command -v jq &>/dev/null; then
    echo "Error: jq not found" >&2
    exit 1
  fi
}

require_rudi() {
  if ! command -v rudi &>/dev/null; then
    echo "Error: rudi not found. Install it: shiv install rudi" >&2
    exit 1
  fi
}

# ── Path helpers ──────────────────────────────────────────────

# Given a module name, return its clone path (absolute).
module_path() {
  local name="$1"
  echo "$(clones_dir)/$name"
}

# ── Manifest operations ──────────────────────────────────────
#
# Manifest format: tab-separated lines, sorted by name.
#   <name>\t<url>\t<pin>[\t<track>]\n
#
# The optional fourth field is a tracking ref. Pins remain the durable
# recorded state; tracking refs let selected modules refresh their local
# gitignored clone during init without dirtying the parent repo.
#
# Line-oriented form lets us use a trivial union merge driver (adapted
# from KnickKnackLabs/notes) for concurrent edits. See
# lib/manifest-merge-driver.sh.

# Print the full manifest to stdout.
manifest_read() {
  if [ -f "$MANIFEST" ]; then
    cat "$MANIFEST"
  fi
}

# Write manifest from stdin. Normalizes: deduplicates by name (first wins),
# sorts alphabetically by name.
manifest_write() {
  local tmp="${MANIFEST}.tmp"
  # awk: keep first occurrence of each name; then sort by name.
  awk -F'\t' '!seen[$1]++' | sort -t$'\t' -k1,1 > "$tmp"
  mv "$tmp" "$MANIFEST"
}

# True (0) if a module with this name exists.
manifest_has() {
  local name="$1"
  [ -f "$MANIFEST" ] || return 1
  awk -F'\t' -v n="$name" '$1 == n { found=1; exit } END { exit !found }' "$MANIFEST"
}

# Print a single manifest line for a name (empty if not found).
manifest_get() {
  local name="$1"
  [ -f "$MANIFEST" ] || return 1
  local line
  line="$(awk -F'\t' -v n="$name" '$1 == n { print; exit }' "$MANIFEST")"
  if [ -z "$line" ]; then
    return 1
  fi
  echo "$line"
}

# Print the URL for a name.
manifest_url() {
  local name="$1"
  manifest_get "$name" | cut -f2
}

# Print the pin for a name.
manifest_pin() {
  local name="$1"
  manifest_get "$name" | cut -f3
}

# Print the optional tracking ref for a name (empty if untracked).
manifest_track() {
  local name="$1"
  manifest_get "$name" | cut -f4
}

# True (0) if the manifest exists and is not git-crypt ciphertext.
manifest_is_readable() {
  [ -f "$MANIFEST" ] || return 1
  if [ ! -s "$MANIFEST" ]; then
    return 0
  fi

  # git-crypt files begin with \0 G I T C R Y P T \0. Bash strings cannot
  # contain the leading NUL, so read bytes 2-9 and compare the ASCII marker.
  local header
  header=$(dd if="$MANIFEST" bs=1 skip=1 count=8 2>/dev/null)
  [ "$header" != "GITCRYPT" ]
}

# Insert or update an entry.
# Usage: manifest_set <name> <url> <pin> [track]
manifest_set() {
  local name="$1" url="$2" pin="$3" track="${4:-}"

  # Validate: no tabs (our delimiter) or newlines (our record separator)
  # in any field. Either would split one entry across lines/columns and
  # corrupt the manifest's keyed-on-name logic.
  if [[ "$name" == *$'\t'* || "$url" == *$'\t'* || "$pin" == *$'\t'* || "$track" == *$'\t'* ]]; then
    echo "Error: manifest fields must not contain tab characters" >&2
    return 1
  fi
  if [[ "$name" == *$'\n'* || "$url" == *$'\n'* || "$pin" == *$'\n'* || "$track" == *$'\n'* ]]; then
    echo "Error: manifest fields must not contain newline characters" >&2
    return 1
  fi

  local tmp="${MANIFEST}.tmp"
  {
    # Copy all other entries
    if [ -f "$MANIFEST" ]; then
      awk -F'\t' -v n="$name" '$1 != n' "$MANIFEST"
    fi
    # Append new entry
    if [ -n "$track" ]; then
      printf '%s\t%s\t%s\t%s\n' "$name" "$url" "$pin" "$track"
    else
      printf '%s\t%s\t%s\n' "$name" "$url" "$pin"
    fi
  } | sort -t$'\t' -k1,1 > "$tmp"
  mv "$tmp" "$MANIFEST"
}

# Remove an entry by name. Silent if not present.
manifest_remove() {
  local name="$1"
  [ -f "$MANIFEST" ] || return 0
  local tmp="${MANIFEST}.tmp"
  if ! awk -F'\t' -v n="$name" '$1 != n' "$MANIFEST" > "$tmp"; then
    rm -f "$tmp"
    echo "Error: failed to rewrite $MANIFEST while removing '$name'" >&2
    return 1
  fi
  mv "$tmp" "$MANIFEST"
}

# List all module names, one per line, sorted.
manifest_names() {
  [ -f "$MANIFEST" ] || return 0
  cut -f1 "$MANIFEST"
}

# Count entries (non-empty lines).
manifest_count() {
  if [ ! -f "$MANIFEST" ]; then
    echo 0
    return
  fi
  awk 'NF' "$MANIFEST" | wc -l | tr -d ' '
}
