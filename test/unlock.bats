#!/usr/bin/env bats
# unlock.bats — test modules unlock task

bats_require_minimum_version 1.5.0

setup() {
  load test_helper

  PARENT="$BATS_TEST_TMPDIR/parent"
  create_parent_repo "$PARENT"
  export MODULES_CALLER_PWD="$PARENT"

  modules setup
  git -C "$PARENT" commit -m "init modules"
}

@test "unlock no-ops when manifest is already readable even with dirty tree" {
  echo "dirty" > "$PARENT/dirty.txt"

  run modules unlock
  [ "$status" -eq 0 ]
  [[ "$output" == *"already unlocked"* ]]
}
