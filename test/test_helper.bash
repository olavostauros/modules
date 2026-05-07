#!/usr/bin/env bash
# test_helper.bash — shared fixtures for modules tests

REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Load this repo's declared tools even when a single test file is run with
# `bats test/foo.bats` from an agent session whose inherited MISE_CONFIG_ROOT
# points at a different repo.
eval "$(cd "$REPO_DIR" && mise env)"

# Run a modules task through mise.
modules() {
  if [ -z "${MODULES_CALLER_PWD:-}" ]; then
    echo "MODULES_CALLER_PWD not set" >&2
    return 1
  fi
  cd "$REPO_DIR" && MODULES_CALLER_PWD="$MODULES_CALLER_PWD" mise run -q "$@"
}
export -f modules

# Create a local "remote" repo with some commits.
# Usage: create_remote_repo <path>
# Returns: the path, with a repo containing 2 commits.
create_remote_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -b main
  git -C "$path" commit --allow-empty -m "initial commit"
  echo "hello" > "$path/README.md"
  git -C "$path" add README.md
  git -C "$path" commit -m "add readme"
}

# Create a parent repo (the one that will contain submodules).
# Usage: create_parent_repo <path>
create_parent_repo() {
  local path="$1"
  mkdir -p "$path"
  git -C "$path" init -b main
  git -C "$path" commit --allow-empty -m "initial commit"
}

# Get the HEAD SHA of a repo.
# Usage: repo_head <path>
repo_head() {
  git -C "$1" rev-parse HEAD
}

# Skip a test if git-crypt is not available.
skip_unless_git_crypt() {
  if ! command -v git-crypt &>/dev/null; then
    skip "git-crypt not installed"
  fi
}

# Skip a test if no GPG key is available for testing.
#
# Resolution order for the test key:
#   1. Pre-set TEST_GPG_FINGERPRINT (explicit override).
#   2. The secret key matching $GIT_AUTHOR_EMAIL (via testicles) — this is
#      the identity-scoped key, not some random first-in-the-keyring.
#   3. Skip if none of the above resolves.
skip_unless_gpg_key() {
  if [ -n "${TEST_GPG_FINGERPRINT:-}" ]; then
    return 0
  fi

  if ! command -v testicles &>/dev/null; then
    skip "testicles not installed (needed to resolve GPG identity key)"
  fi

  local email="${GIT_AUTHOR_EMAIL:-}"
  if [ -z "$email" ]; then
    skip "GIT_AUTHOR_EMAIL not set — cannot resolve identity key"
  fi

  local fpr
  fpr="$(testicles inspect "$email" --first --json 2>/dev/null | jq -r '.fingerprint // empty')" || true
  if [ -z "$fpr" ]; then
    skip "no secret key matches $email"
  fi

  export TEST_GPG_FINGERPRINT="$fpr"
}

# Test helpers for the line-oriented TSV manifest.
# Usage: manifest_line_of <manifest-path> <name>
manifest_line_of() {
  awk -F'\t' -v n="$2" '$1 == n { print; exit }' "$1" 2>/dev/null
}
manifest_url_of() {
  manifest_line_of "$1" "$2" | cut -f2
}
manifest_pin_of() {
  manifest_line_of "$1" "$2" | cut -f3
}
manifest_track_of() {
  manifest_line_of "$1" "$2" | cut -f4
}
manifest_count_of() {
  if [ ! -f "$1" ]; then echo 0; return; fi
  awk 'NF' "$1" | wc -l | tr -d ' '
}
manifest_has_name() {
  [ -f "$1" ] || return 1
  awk -F'\t' -v n="$2" '$1 == n { f=1; exit } END { exit !f }' "$1"
}
export -f manifest_line_of manifest_url_of manifest_pin_of manifest_track_of manifest_count_of manifest_has_name

# Import module_path from common.sh — single source of truth.
# Note: common.sh requires MODULES_CALLER_PWD; tests using module_path must set it first.
# shellcheck source=../lib/common.sh
# Source in a subshell-safe way: common.sh uses set -euo pipefail but we want the
# functions available in the current shell.
MODULES_CALLER_PWD="${MODULES_CALLER_PWD:-/tmp}" source "$REPO_DIR/lib/common.sh"
export -f module_path
