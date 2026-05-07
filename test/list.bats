#!/usr/bin/env bats
# list.bats — test modules list task

bats_require_minimum_version 1.5.0

setup() {
  load test_helper

  REMOTE="$BATS_TEST_TMPDIR/remote"
  PARENT="$BATS_TEST_TMPDIR/parent"

  create_remote_repo "$REMOTE"
  create_parent_repo "$PARENT"
  export MODULES_CALLER_PWD="$PARENT"

  modules setup
  git -C "$PARENT" commit -m "init modules"
}

@test "list shows empty message with no modules" {
  run modules list
  [ "$status" -eq 0 ]
  [[ "$output" == *"No modules"* ]]
}

@test "list shows module after add" {
  modules add "$REMOTE" --name my-repo
  run modules list
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-repo"* ]]
  [[ "$output" == *"$REMOTE"* ]]
}

@test "list --json outputs valid JSON" {
  modules add "$REMOTE" --name my-repo
  run modules list --json
  [ "$status" -eq 0 ]

  # Should be parseable JSON with our module
  echo "$output" | jq -e '.["my-repo"].url' >/dev/null
}

@test "list --json includes track when present" {
  modules add "$REMOTE" --name tracked --track main
  run modules list --json
  [ "$status" -eq 0 ]

  local track
  track="$(echo "$output" | jq -r '.tracked.track')"
  [ "$track" = "main" ]
}

@test "list --json escapes quotes/backslashes in URLs safely" {
  # Write a manifest line by hand with a URL containing a double-quote and
  # a backslash — exactly the shape that broke the old awk-based encoder.
  modules add "$REMOTE" --name evil
  local manifest="$PARENT/.modules/manifest"
  # Decrypt-in-place isn't needed here: git-crypt is active only if initialized;
  # for these tests the manifest is plaintext TSV.
  printf 'evil\thttps://example.com/a"b\\c\tdeadbeef\n' > "$manifest"

  run modules list --json
  [ "$status" -eq 0 ]
  # Output must be valid JSON (would fail with the old awk encoder).
  echo "$output" | jq -e '.' >/dev/null
  # The URL should round-trip exactly, including the quote and backslash.
  local got
  got=$(echo "$output" | jq -r '.evil.url')
  [ "$got" = 'https://example.com/a"b\c' ]
}

@test "list shows multiple modules" {
  local remote2="$BATS_TEST_TMPDIR/remote2"
  create_remote_repo "$remote2"

  modules add "$REMOTE" --name first
  modules add "$remote2" --name second

  run modules list
  [ "$status" -eq 0 ]
  [[ "$output" == *"first"* ]]
  [[ "$output" == *"second"* ]]
}
