#!/usr/bin/env bats
# init.bats — test modules init task

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

@test "init with no modules prints message" {
  run modules init
  [ "$status" -eq 0 ]
  [[ "$output" == *"No modules"* ]]
}

@test "init clones modules from manifest into readable paths" {
  modules add "$REMOTE" --name my-repo
  git -C "$PARENT" commit -m "add module"

  # Simulate fresh clone: remove the clone but keep the manifest
  rm -rf "$PARENT/modules/my-repo"

  run modules init
  [ "$status" -eq 0 ]
  [[ "$output" == *"my-repo"* ]]

  # Clone should be restored
  [ -d "$PARENT/modules/my-repo/.git" ]
  [ -f "$PARENT/modules/my-repo/README.md" ]
}

@test "init checks out the pinned SHA" {
  modules add "$REMOTE" --name my-repo
  git -C "$PARENT" commit -m "add module"

  local pin
  pin="$(manifest_pin_of "$PARENT/.modules/manifest" "my-repo")"

  # Remove clone
  rm -rf "$PARENT/modules/my-repo"

  modules init

  # Should be at pinned commit
  local actual
  actual="$(repo_head "$PARENT/modules/my-repo")"
  [ "$actual" = "$pin" ]
}

@test "init skips already-cloned untracked modules" {
  modules add "$REMOTE" --name my-repo

  run modules init
  [ "$status" -eq 0 ]
  [[ "$output" == *"already cloned"* ]]
}

@test "init refreshes already-cloned tracked modules without updating manifest pin" {
  modules add "$REMOTE" --name tracked --track main
  git -C "$PARENT" commit -m "add tracked module"

  local old_pin
  old_pin="$(manifest_pin_of "$PARENT/.modules/manifest" "tracked")"

  echo "fresh" > "$REMOTE/fresh.md"
  git -C "$REMOTE" add fresh.md
  git -C "$REMOTE" commit -m "fresh commit"
  local latest
  latest="$(repo_head "$REMOTE")"

  run modules init
  [ "$status" -eq 0 ]
  [[ "$output" == *"tracking main"* ]]

  local actual pin_after branch upstream
  actual="$(repo_head "$PARENT/modules/tracked")"
  pin_after="$(manifest_pin_of "$PARENT/.modules/manifest" "tracked")"
  branch="$(git -C "$PARENT/modules/tracked" symbolic-ref --short HEAD)"
  upstream="$(git -C "$PARENT/modules/tracked" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  [ "$actual" = "$latest" ]
  [ "$pin_after" = "$old_pin" ]
  [ "$branch" = "main" ]
  [ "$upstream" = "origin/main" ]
}

@test "init converts detached tracked clone back to local tracking branch" {
  modules add "$REMOTE" --name tracked --track main
  git -C "$PARENT" commit -m "add tracked module"

  git -C "$PARENT/modules/tracked" checkout -q --detach HEAD

  echo "fresh" > "$REMOTE/fresh.md"
  git -C "$REMOTE" add fresh.md
  git -C "$REMOTE" commit -m "fresh commit"
  local latest
  latest="$(repo_head "$REMOTE")"

  run modules init
  [ "$status" -eq 0 ]

  local actual branch upstream
  actual="$(repo_head "$PARENT/modules/tracked")"
  branch="$(git -C "$PARENT/modules/tracked" symbolic-ref --short HEAD)"
  upstream="$(git -C "$PARENT/modules/tracked" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}')"
  [ "$actual" = "$latest" ]
  [ "$branch" = "main" ]
  [ "$upstream" = "origin/main" ]
}

@test "init refuses dirty tracked clones" {
  modules add "$REMOTE" --name tracked --track main

  echo "local work" > "$PARENT/modules/tracked/local.md"

  run modules init
  [ "$status" -ne 0 ]
  [[ "$output" == *"uncommitted changes"* ]]
}

@test "init refuses detached tracked clones with local-only commits" {
  modules add "$REMOTE" --name tracked --track main
  git -C "$PARENT" commit -m "add tracked module"

  git -C "$PARENT/modules/tracked" checkout -q --detach HEAD
  echo "detached work" > "$PARENT/modules/tracked/detached.md"
  git -C "$PARENT/modules/tracked" add detached.md
  git -C "$PARENT/modules/tracked" commit -m "detached local work"

  run modules init
  [ "$status" -ne 0 ]
  [[ "$output" == *"detached HEAD has commits not in origin/main"* ]]
}

@test "init reports failure when clone fails" {
  # Add a module with a bogus URL directly in the manifest (TSV format)
  printf 'bad-repo\tfile:///nonexistent/repo.git\t0000000000000000000000000000000000000000\n' \
    >> "$PARENT/.modules/manifest"

  run modules init
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed"* ]]
}

@test "init handles multiple modules" {
  local remote2="$BATS_TEST_TMPDIR/remote2"
  create_remote_repo "$remote2"

  modules add "$REMOTE" --name first
  modules add "$remote2" --name second
  git -C "$PARENT" commit -m "add modules"

  # Remove both clones
  rm -rf "$PARENT/modules/first" "$PARENT/modules/second"

  run modules init
  [ "$status" -eq 0 ]
  [ -d "$PARENT/modules/first/.git" ]
  [ -d "$PARENT/modules/second/.git" ]
}

@test "init can initialize only selected modules" {
  local remote2="$BATS_TEST_TMPDIR/remote2"
  create_remote_repo "$remote2"

  modules add "$REMOTE" --name first
  modules add "$remote2" --name second
  git -C "$PARENT" commit -m "add modules"

  rm -rf "$PARENT/modules/first" "$PARENT/modules/second"

  run modules init second
  [ "$status" -eq 0 ]
  [[ "$output" == *"second"* ]]
  [[ "$output" != *"first"* ]]
  [ ! -e "$PARENT/modules/first" ]
  [ -d "$PARENT/modules/second/.git" ]
}

@test "init can initialize multiple selected modules" {
  local remote2="$BATS_TEST_TMPDIR/remote2"
  local remote3="$BATS_TEST_TMPDIR/remote3"
  create_remote_repo "$remote2"
  create_remote_repo "$remote3"

  modules add "$REMOTE" --name first
  modules add "$remote2" --name second
  modules add "$remote3" --name third
  git -C "$PARENT" commit -m "add modules"

  rm -rf "$PARENT/modules/first" "$PARENT/modules/second" "$PARENT/modules/third"

  run modules init first third
  [ "$status" -eq 0 ]
  [[ "$output" == *"first"* ]]
  [[ "$output" != *"second"* ]]
  [[ "$output" == *"third"* ]]
  [ -d "$PARENT/modules/first/.git" ]
  [ ! -e "$PARENT/modules/second" ]
  [ -d "$PARENT/modules/third/.git" ]
}

@test "init selected modules skips unselected clone failures" {
  modules add "$REMOTE" --name good
  printf 'private\tfile:///nonexistent/private.git\t0000000000000000000000000000000000000000\n' \
    >> "$PARENT/.modules/manifest"
  git -C "$PARENT" add .modules/manifest
  git -C "$PARENT" commit -m "add modules"

  rm -rf "$PARENT/modules/good"

  run modules init good
  [ "$status" -eq 0 ]
  [[ "$output" == *"good"* ]]
  [[ "$output" != *"private"* ]]
  [ -d "$PARENT/modules/good/.git" ]
  [ ! -e "$PARENT/modules/private" ]
}

@test "init fails clearly for unknown selected modules before cloning" {
  modules add "$REMOTE" --name good
  git -C "$PARENT" commit -m "add module"

  rm -rf "$PARENT/modules/good"

  run modules init missing
  [ "$status" -ne 0 ]
  [[ "$output" == *"module 'missing' not found"* ]]
  [ ! -e "$PARENT/modules/good" ]
}
