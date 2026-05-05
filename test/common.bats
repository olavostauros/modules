#!/usr/bin/env bats
# common.bats — test shared helpers

bats_require_minimum_version 1.5.0

setup() {
  load test_helper
  # Fresh fake repo per test so config writes don't leak between cases
  FAKE_REPO="$BATS_TEST_TMPDIR/fake-repo"
  mkdir -p "$FAKE_REPO"
  CALLER_PWD="$FAKE_REPO"
  export CALLER_PWD
  source "$REPO_DIR/lib/common.sh"
}

@test "module_path defaults to modules/<name> when no config" {
  local p
  p="$(module_path "fold")"
  [ "$p" = "$FAKE_REPO/modules/fold" ]
}

@test "module_path honors .modules/config path override" {
  mkdir -p "$FAKE_REPO/.modules"
  echo '{"path": "deps"}' > "$FAKE_REPO/.modules/config"
  local p
  p="$(module_path "fold")"
  [ "$p" = "$FAKE_REPO/deps/fold" ]
}

@test "module_path handles names with dots" {
  local p
  p="$(module_path "org.repo")"
  [ "$p" = "$FAKE_REPO/modules/org.repo" ]
}

@test "module_path handles hyphens and underscores" {
  local p
  p="$(module_path "my-dep_v2")"
  [ "$p" = "$FAKE_REPO/modules/my-dep_v2" ]
}

@test "clones_path_rel returns default when no config" {
  run clones_path_rel
  [ "$output" = "modules" ]
}

@test "clones_path_rel reads from config when set" {
  mkdir -p "$FAKE_REPO/.modules"
  echo '{"path": "third-party/vendored"}' > "$FAKE_REPO/.modules/config"
  run clones_path_rel
  [ "$output" = "third-party/vendored" ]
}

# ── manifest_set validation ──

@test "manifest_set rejects tabs in any field" {
  mkdir -p "$FAKE_REPO/.modules"
  MANIFEST="$FAKE_REPO/.modules/manifest"
  : > "$MANIFEST"

  run manifest_set $'bad\tname' 'https://example.com' 'deadbeef'
  [ "$status" -ne 0 ]
  [[ "$output" == *"tab characters"* ]]

  run manifest_set 'ok' $'https://example.com\textra' 'deadbeef'
  [ "$status" -ne 0 ]

  run manifest_set 'ok' 'https://example.com' $'dead\tbeef'
  [ "$status" -ne 0 ]

  run manifest_set 'ok' 'https://example.com' 'deadbeef' $'main\textra'
  [ "$status" -ne 0 ]
}

@test "manifest_set rejects newlines in any field" {
  mkdir -p "$FAKE_REPO/.modules"
  MANIFEST="$FAKE_REPO/.modules/manifest"
  : > "$MANIFEST"

  run manifest_set $'bad\nname' 'https://example.com' 'deadbeef'
  [ "$status" -ne 0 ]
  [[ "$output" == *"newline characters"* ]]

  run manifest_set 'ok' $'https://example.com\nmalicious' 'deadbeef'
  [ "$status" -ne 0 ]

  run manifest_set 'ok' 'https://example.com' $'dead\nbeef'
  [ "$status" -ne 0 ]

  run manifest_set 'ok' 'https://example.com' 'deadbeef' $'main\nmalicious'
  [ "$status" -ne 0 ]
}
