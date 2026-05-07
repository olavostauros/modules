#!/usr/bin/env bats
# status.bats — test modules status task

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

@test "status shows at pin for clean module" {
  modules add "$REMOTE" --name my-repo

  run modules status
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-repo"* ]]
  [[ "$output" == *"at pin"* ]]
}

@test "status shows changed when module has new commits" {
  modules add "$REMOTE" --name my-repo

  # Make a new commit in the clone
  echo "new" > "$PARENT/modules/my-repo/new.md"
  git -C "$PARENT/modules/my-repo" add new.md
  git -C "$PARENT/modules/my-repo" commit -m "new commit"

  run modules status
  [ "$status" -eq 0 ]
  [[ "$output" == *"changed"* ]]
}

@test "status shows missing when clone is absent" {
  modules add "$REMOTE" --name my-repo
  git -C "$PARENT" commit -m "add module"

  rm -rf "$PARENT/modules/my-repo"

  run modules status
  [ "$status" -eq 0 ]
  [[ "$output" == *"missing"* ]]
}

@test "status shows tracking ref" {
  modules add "$REMOTE" --name tracked --track main

  echo "new" > "$REMOTE/new.md"
  git -C "$REMOTE" add new.md
  git -C "$REMOTE" commit -m "new commit"
  modules init

  run modules status
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracked"* ]]
  [[ "$output" == *"main"* ]]
  [[ "$output" == *"tracking"* ]]
}
