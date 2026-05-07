#!/usr/bin/env bats
# update.bats — test modules update task

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

@test "update pulls new commits and updates pin" {
  modules add "$REMOTE" --name my-repo
  git -C "$PARENT" commit -m "add module"

  local old_pin
  old_pin="$(manifest_pin_of "$PARENT/.modules/manifest" "my-repo")"

  # Push a new commit to the remote
  echo "upstream change" > "$REMOTE/upstream.md"
  git -C "$REMOTE" add upstream.md
  git -C "$REMOTE" commit -m "upstream update"

  run modules update my-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated"* ]]
  [[ "$output" == *"Manifest changes staged"* ]]

  local new_pin
  new_pin="$(manifest_pin_of "$PARENT/.modules/manifest" "my-repo")"
  [ "$old_pin" != "$new_pin" ]
}

@test "update tracked module advances pin from tracked ref and preserves track" {
  modules add "$REMOTE" --name tracked --track main
  git -C "$PARENT" commit -m "add tracked module"

  local old_pin
  old_pin="$(manifest_pin_of "$PARENT/.modules/manifest" "tracked")"

  echo "tracked change" > "$REMOTE/tracked.md"
  git -C "$REMOTE" add tracked.md
  git -C "$REMOTE" commit -m "tracked update"

  run modules update tracked
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracking main"* ]]
  [[ "$output" == *"updated"* ]]

  local new_pin track
  new_pin="$(manifest_pin_of "$PARENT/.modules/manifest" "tracked")"
  track="$(manifest_track_of "$PARENT/.modules/manifest" "tracked")"
  [ "$old_pin" != "$new_pin" ]
  [ "$track" = "main" ]
}

@test "update --commit commits manifest changes" {
  modules add "$REMOTE" --name my-repo
  git -C "$PARENT" commit -m "add module"

  echo "committed change" > "$REMOTE/committed.md"
  git -C "$REMOTE" add committed.md
  git -C "$REMOTE" commit -m "committed update"

  run modules update my-repo --commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"deps: update my-repo module pin"* ]]

  run git -C "$PARENT" status --short
  [ -z "$output" ]
}

@test "update --commit leaves unrelated staged changes alone" {
  modules add "$REMOTE" --name my-repo
  git -C "$PARENT" commit -m "add module"

  echo "unrelated" > "$PARENT/unrelated.txt"
  git -C "$PARENT" add unrelated.txt

  echo "committed change" > "$REMOTE/committed.md"
  git -C "$REMOTE" add committed.md
  git -C "$REMOTE" commit -m "committed update"

  run modules update my-repo --commit
  [ "$status" -eq 0 ]
  [[ "$output" == *"deps: update my-repo module pin"* ]]

  run git -C "$PARENT" status --short
  [[ "$output" == *"A  unrelated.txt"* ]]

  run git -C "$PARENT" show --name-only --format= HEAD
  [[ "$output" == *".modules/manifest"* ]]
  [[ "$output" != *"unrelated.txt"* ]]
}

@test "update reports already up to date" {
  modules add "$REMOTE" --name my-repo

  run modules update my-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
}

@test "update all modules when no name given" {
  local remote2="$BATS_TEST_TMPDIR/remote2"
  create_remote_repo "$remote2"

  modules add "$REMOTE" --name first
  modules add "$remote2" --name second
  git -C "$PARENT" commit -m "add modules"

  # Push changes to both remotes
  echo "change1" > "$REMOTE/change.md"
  git -C "$REMOTE" add change.md
  git -C "$REMOTE" commit -m "change 1"

  echo "change2" > "$remote2/change.md"
  git -C "$remote2" add change.md
  git -C "$remote2" commit -m "change 2"

  run modules update
  [ "$status" -eq 0 ]
  [[ "$output" == *"first"*"updated"* ]]
  [[ "$output" == *"second"*"updated"* ]]
}

@test "update works after init (detached HEAD)" {
  modules add "$REMOTE" --name my-repo
  git -C "$PARENT" commit -m "add module"

  # Simulate fresh clone: remove the clone, re-init (which detaches HEAD)
  rm -rf "$PARENT/modules/my-repo"
  modules init

  # Push a new commit to the remote
  echo "new stuff" > "$REMOTE/new.md"
  git -C "$REMOTE" add new.md
  git -C "$REMOTE" commit -m "new commit"

  # Update should succeed despite detached HEAD from init
  run modules update my-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated"* ]]
}

@test "update ignores stale local branch and uses default branch" {
  modules add "$REMOTE" --name my-repo
  git -C "$PARENT" commit -m "add module"

  git -C "$PARENT/modules/my-repo" checkout -b stale-local

  echo "default branch change" > "$REMOTE/default.md"
  git -C "$REMOTE" add default.md
  git -C "$REMOTE" commit -m "default update"
  local latest
  latest="$(repo_head "$REMOTE")"

  run modules update my-repo
  [ "$status" -eq 0 ]
  [[ "$output" == *"updated"* ]]

  local actual
  actual="$(repo_head "$PARENT/modules/my-repo")"
  [ "$actual" = "$latest" ]
}

@test "update all reports failure when a module fails" {
  local remote2="$BATS_TEST_TMPDIR/remote2"
  create_remote_repo "$remote2"

  modules add "$REMOTE" --name first
  modules add "$remote2" --name second
  git -C "$PARENT" commit -m "add modules"

  # Break the first module's clone so pull fails
  rm -rf "$PARENT/modules/first/.git"
  mkdir -p "$PARENT/modules/first/.git"  # broken .git dir

  run modules update
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to update"* ]]
}

@test "update fails for unknown module" {
  run modules update nonexistent
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}
