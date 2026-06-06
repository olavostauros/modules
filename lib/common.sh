#!/usr/bin/env bash
# common.sh — shared helpers for modules tasks

set -euo pipefail

# The target repo is the modules invocation cwd (set by the shiv shim).
# Prefer the package-specific variable; keep CALLER_PWD as a temporary
# legacy fallback while the ecosystem migrates.
TARGET_DIR="${MODULES_CALLER_PWD:-${CALLER_PWD:-.}}"

# Where modules metadata lives (tracked; manifest encrypted, config plaintext).
MODULES_DIR="$TARGET_DIR/.modules"
MANIFEST="$MODULES_DIR/manifest"
CONFIG="$MODULES_DIR/config"

# Current layout version. Written into .modules/config at setup; read by
# require_initialized to detect incompatible repos (old layout, future
# layout) and produce actionable errors rather than silent misbehavior.
MODULES_LAYOUT_VERSION="0.9.0"

# Paths tracked in git-relative form (for hooks / diff matching).
# These constants are consumed by task scripts after sourcing this file.
# shellcheck disable=SC2034
MANIFEST_REL=".modules/manifest"
# shellcheck disable=SC2034
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

# Sync a tracked module to a local branch following origin/<branch>.
#
# Tracked modules are editable checkouts, not immutable dependency pins. Keep
# them on a normal local branch so `git status`, `git pull`, and topic-branch
# workflows behave like users expect. Refuse dirty/ahead/diverged checkouts
# instead of silently overwriting local work.
sync_tracked_branch() {
  local name="$1" mod_path="$2" branch="$3"

  local dirty
  if ! dirty="$(git -C "$mod_path" status --porcelain)"; then
    echo "  $name: failed to inspect worktree before syncing tracked branch '$branch'" >&2
    return 1
  fi
  if [ -n "$dirty" ]; then
    echo "  $name: worktree has uncommitted changes; refusing to sync tracked branch '$branch'" >&2
    return 1
  fi

  if ! git -C "$mod_path" fetch -q origin "refs/heads/$branch:refs/remotes/origin/$branch" 2>&1; then
    echo "  $name: failed to fetch tracked branch '$branch'" >&2
    return 1
  fi

  local current_branch current_head
  if ! current_branch="$(git -C "$mod_path" symbolic-ref --quiet --short HEAD)"; then
    current_branch=""
  fi
  current_head="$(git -C "$mod_path" rev-parse HEAD)"
  if [ -z "$current_branch" ] && ! git -C "$mod_path" merge-base --is-ancestor "$current_head" "origin/$branch"; then
    echo "  $name: detached HEAD has commits not in origin/$branch; refusing to overwrite" >&2
    return 1
  fi

  if git -C "$mod_path" show-ref --verify --quiet "refs/heads/$branch"; then
    if ! git -C "$mod_path" checkout -q "$branch" 2>&1; then
      echo "  $name: failed to checkout local branch '$branch'" >&2
      return 1
    fi
  else
    if ! git -C "$mod_path" checkout -q -b "$branch" --track "origin/$branch" 2>&1; then
      echo "  $name: failed to create local branch '$branch' tracking origin/$branch" >&2
      return 1
    fi
  fi

  if ! git -C "$mod_path" branch --set-upstream-to="origin/$branch" "$branch" >/dev/null 2>&1; then
    echo "  $name: failed to set upstream for '$branch' to origin/$branch" >&2
    return 1
  fi

  local local_sha remote_sha
  local_sha="$(git -C "$mod_path" rev-parse "$branch")"
  remote_sha="$(git -C "$mod_path" rev-parse "origin/$branch")"

  if [ "$local_sha" = "$remote_sha" ]; then
    return 0
  fi

  if git -C "$mod_path" merge-base --is-ancestor "$local_sha" "$remote_sha"; then
    if ! git -C "$mod_path" merge --ff-only -q "origin/$branch" 2>&1; then
      echo "  $name: failed to fast-forward '$branch' to origin/$branch" >&2
      return 1
    fi
    return 0
  fi

  echo "  $name: local branch '$branch' has commits not in origin/$branch; refusing to overwrite" >&2
  return 1
}

# ── Confirm-or-require-yes ─────────────────────────────────────

# Confirm a destructive operation or require --yes to proceed.
# The calling task must declare #USAGE flag "-y --yes" default=#false so
# that mise sets usage_yes=true when the flag is passed.
# Returns 0 if confirmed, 1 if refused.
confirm_or_require_yes() {
  local message="$1"

  if [ "${usage_yes:-}" = "true" ]; then
    return 0
  fi

  if [ -t 0 ] && [ -t 1 ] && [ -z "${BATS_TEST_NAME:-}" ] && [ -z "${CI:-}" ]; then
    gum confirm "$message" && return 0 || return 1
  fi

  echo "  Re-run with --yes to confirm." >&2
  return 1
}

# ── Manifest operations ──────────────────────────────────────
#
# Manifest format: tab-separated lines, sorted by name.
#   <name>\t<url>\t<pin>[\t<track>]\n
#
# The optional fourth field is a tracking branch. Pins remain the durable
# recorded state; tracking branches let selected modules refresh their local
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

# Print the optional tracking branch for a name (empty if untracked).
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
