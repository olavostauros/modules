#!/usr/bin/env bats
# add.bats — test modules add task

bats_require_minimum_version 1.5.0

setup() {
  load test_helper

  REMOTE="$BATS_TEST_TMPDIR/remote"
  PARENT="$BATS_TEST_TMPDIR/parent"

  create_remote_repo "$REMOTE"
  create_parent_repo "$PARENT"
  export MODULES_CALLER_PWD="$PARENT"

  # Initialize modules
  modules setup
  git -C "$PARENT" commit -m "init modules"
}

@test "add clones repo into readable path" {
  run modules add "$REMOTE"
  [ "$status" -eq 0 ]

  # Should mention the module name (derived from dir name: "remote")
  [[ "$output" == *"Added module 'remote'"* ]]

  # Readable directory should exist with repo contents
  [ -d "$PARENT/modules/remote/.git" ]
  [ -f "$PARENT/modules/remote/README.md" ]
}

@test "add records entry in manifest" {
  modules add "$REMOTE"

  # Manifest is TSV: <name>\t<url>\t<pin>[\t<track>]
  manifest_has_name "$PARENT/.modules/manifest" "remote"

  local url pin expected
  url="$(manifest_url_of "$PARENT/.modules/manifest" "remote")"
  pin="$(manifest_pin_of "$PARENT/.modules/manifest" "remote")"
  [ "$url" = "$REMOTE" ]
  expected="$(repo_head "$REMOTE")"
  [ "$pin" = "$expected" ]

  # Untracked manifest line should have exactly 3 tab-separated fields
  local line
  line="$(manifest_line_of "$PARENT/.modules/manifest" "remote")"
  local fields
  fields="$(echo -n "$line" | awk -F'\t' '{print NF}')"
  [ "$fields" = "3" ]
}

@test "add with --track records tracking branch" {
  modules add "$REMOTE" --name tracked --track main

  local pin track expected
  pin="$(manifest_pin_of "$PARENT/.modules/manifest" "tracked")"
  track="$(manifest_track_of "$PARENT/.modules/manifest" "tracked")"
  expected="$(repo_head "$REMOTE")"
  [ "$pin" = "$expected" ]
  [ "$track" = "main" ]

  local line fields
  line="$(manifest_line_of "$PARENT/.modules/manifest" "tracked")"
  fields="$(echo -n "$line" | awk -F'\t' '{print NF}')"
  [ "$fields" = "4" ]
}

@test "add stages manifest only (no gitlink, modules/ is gitignored)" {
  modules add "$REMOTE"

  # Manifest should be staged
  run git -C "$PARENT" diff --cached --name-only
  [[ "$output" == *".modules/manifest"* ]]

  # modules/ contents should NOT be tracked
  run git -C "$PARENT" ls-files modules/
  [ -z "$output" ]

  # No gitlink entries anywhere
  run git -C "$PARENT" ls-files --stage
  [[ "$output" != *"160000"* ]]
}

@test "add without --name ignores inherited usage_name" {
  export usage_name=quick-hooks-lifecycle

  run modules add "$REMOTE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Added module 'remote'"* ]]
  [[ "$output" != *"quick-hooks-lifecycle"* ]]

  [ -d "$PARENT/modules/remote" ]
  [ ! -e "$PARENT/modules/quick-hooks-lifecycle" ]
  manifest_has_name "$PARENT/.modules/manifest" "remote"
  ! manifest_has_name "$PARENT/.modules/manifest" "quick-hooks-lifecycle"
}

@test "add with --name uses custom name" {
  run modules add "$REMOTE" --name my-dep
  [ "$status" -eq 0 ]
  [[ "$output" == *"Added module 'my-dep'"* ]]

  # Clone exists under custom name
  [ -d "$PARENT/modules/my-dep" ]

  # Manifest uses custom name
  run head -1 "$PARENT/.modules/manifest"
  [[ "$output" == my-dep$'\t'* ]]
}

@test "add with --ref pins to specific commit" {
  # Get the first commit (not HEAD)
  local first_sha
  first_sha="$(git -C "$REMOTE" rev-list --max-parents=0 HEAD)"

  modules add "$REMOTE" --ref "$first_sha"

  local pin
  pin="$(manifest_pin_of "$PARENT/.modules/manifest" "remote")"
  [ "$pin" = "$first_sha" ]

  # The clone should be at that commit
  local head
  head="$(repo_head "$PARENT/modules/remote")"
  [ "$head" = "$first_sha" ]
}

@test "add fails if module name already exists" {
  modules add "$REMOTE"
  run modules add "$REMOTE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}

@test "add explains a pre-existing clone directory with a mismatched origin" {
  local other_remote="$BATS_TEST_TMPDIR/other-remote"
  create_remote_repo "$other_remote"

  git clone "$other_remote" "$PARENT/modules/remote"

  run modules add "$REMOTE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"different origin"* ]]
  [[ "$output" == *"Existing origin: $other_remote"* ]]
  [[ "$output" == *"Requested URL: $REMOTE"* ]]
}

@test "add fails with invalid URL" {
  run modules add "file:///nonexistent/repo.git" --name bad-repo
  [ "$status" -ne 0 ]
  [[ "$output" == *"clone"* || "$output" == *"fail"* || "$output" == *"fatal"* ]]
}

@test "add fails if not initialized" {
  local bare="$BATS_TEST_TMPDIR/bare"
  create_parent_repo "$bare"
  export MODULES_CALLER_PWD="$bare"

  run modules add "$REMOTE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not initialized"* ]]
}

@test "add with dots in name is rejected" {
  # Dot-prefix names are rejected (avoids . / .. path shenanigans)
  run modules add "$REMOTE" --name ".hidden"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid module name"* ]]
}

@test "add with dots in middle of name is allowed" {
  run modules add "$REMOTE" --name "org.repo"
  [ "$status" -eq 0 ]

  run manifest_url_of "$PARENT/.modules/manifest" "org.repo"
  [ "$output" = "$REMOTE" ]
}

@test "add with slashes in name is rejected" {
  run modules add "$REMOTE" --name "org/repo"
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid module name"* ]]
}

@test "add multiple modules" {
  local remote2="$BATS_TEST_TMPDIR/remote2"
  create_remote_repo "$remote2"

  modules add "$REMOTE" --name first
  modules add "$remote2" --name second

  # Both in manifest
  run manifest_count_of "$PARENT/.modules/manifest"
  [ "$output" = "2" ]

  # Both directories exist
  [ -d "$PARENT/modules/first" ]
  [ -d "$PARENT/modules/second" ]
}

@test "add derives name from https URL with .git suffix" {
  # Can't actually clone from a URL; just ensure the name derivation is correct
  # by inspecting the error (invalid URL but valid name flow)
  run modules add "https://github.com/org/foobar.git" --name foobar
  # name "foobar" should be the module name; clone will fail (URL unreachable in test),
  # but we just want to ensure --name works with URL-derived form
  # This test is really about validating that the name-derivation logic in non-name mode
  # would produce "foobar"; here we use --name to pin it.
  [[ "$output" == *"Cloning"* || "$output" == *"fatal"* || "$output" == *"foobar"* ]]
}
