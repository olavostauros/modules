#!/usr/bin/env bats
# hooks.bats — test pre-commit leak prevention hooks

bats_require_minimum_version 1.5.0

setup() {
  load test_helper

  PARENT="$BATS_TEST_TMPDIR/parent"
  REMOTE="$BATS_TEST_TMPDIR/remote"

  create_remote_repo "$REMOTE"
  create_parent_repo "$PARENT"
  export MODULES_CALLER_PWD="$PARENT"

  modules setup
  git -C "$PARENT" commit -m "init modules"
}

# ── Dispatcher ─────────────────────────────────────────────────

@test "setup installs pre-commit dispatcher" {
  [ -x "$PARENT/.git/hooks/pre-commit" ]
}

@test "setup preserves existing pre-commit hook" {
  # Simulate a repo that already has a pre-commit dispatcher with a custom hook
  local fresh="$BATS_TEST_TMPDIR/fresh"
  create_parent_repo "$fresh"
  mkdir -p "$fresh/.git/hooks/pre-commit.d"
  cat > "$fresh/.git/hooks/pre-commit" <<'DISPATCH'
#!/usr/bin/env bash
for hook in "$(dirname "$0")/pre-commit.d"/*; do
  [ -x "$hook" ] && "$hook" || exit $?
done
DISPATCH
  chmod +x "$fresh/.git/hooks/pre-commit"
  cat > "$fresh/.git/hooks/pre-commit.d/existing-hook" <<'HOOK'
#!/usr/bin/env bash
echo "existing hook ran"
HOOK
  chmod +x "$fresh/.git/hooks/pre-commit.d/existing-hook"

  export MODULES_CALLER_PWD="$fresh"
  modules setup

  # Existing hook should still be there
  [ -x "$fresh/.git/hooks/pre-commit.d/existing-hook" ]
  # Modules hooks should also be installed
  [ -x "$fresh/.git/hooks/pre-commit.d/gitmodules-guard" ]
  [ -x "$fresh/.git/hooks/pre-commit.d/manifest-encryption" ]
}

@test "setup installs two hooks (no path-obfuscation in opacity redesign)" {
  [ -x "$PARENT/.git/hooks/pre-commit.d/manifest-encryption" ]
  [ -x "$PARENT/.git/hooks/pre-commit.d/gitmodules-guard" ]
  # path-obfuscation hook should NOT be installed — the new design doesn't need it
  [ ! -e "$PARENT/.git/hooks/pre-commit.d/path-obfuscation" ]
}

@test "setup warns when preserved pre-commit does not dispatch pre-commit.d" {
  local fresh="$BATS_TEST_TMPDIR/no-dispatch"
  local existing_hook="$fresh/.git/hooks/pre-commit"
  local guards_dir="$fresh/.git/hooks/pre-commit.d"
  create_parent_repo "$fresh"
  cat > "$existing_hook" <<'EOF'
#!/usr/bin/env bash
echo "my custom hook"
EOF
  chmod +x "$existing_hook"

  export MODULES_CALLER_PWD="$fresh"
  run modules setup

  [ "$status" -eq 0 ]
  [[ "$output" == *"Warning: preserved existing pre-commit hook:"* ]]
  [[ "$output" == *"$existing_hook"* ]]
  [[ "$output" == *"does not appear to dispatch pre-commit.d/"* ]]
  [[ "$output" == *"Modules guards were installed in:"* ]]
  [[ "$output" == *"$guards_dir/"* ]]
  [[ "$output" == *"modules install-hooks"* ]]
  [[ "$output" != *"mise run install-hooks"* ]]
  grep -qF 'echo "my custom hook"' "$existing_hook"
  [ -x "$guards_dir/gitmodules-guard" ]
  [ -x "$guards_dir/manifest-encryption" ]
}

@test "setup quiet when preserved pre-commit dispatches pre-commit.d" {
  local fresh="$BATS_TEST_TMPDIR/dispatches"
  create_parent_repo "$fresh"
  cat > "$fresh/.git/hooks/pre-commit" <<'DISPATCH'
#!/usr/bin/env bash
for hook in "$(dirname "$0")/pre-commit.d"/*; do
  [ -x "$hook" ] && "$hook" || exit $?
done
DISPATCH
  chmod +x "$fresh/.git/hooks/pre-commit"

  export MODULES_CALLER_PWD="$fresh"
  run modules setup

  [ "$status" -eq 0 ]
  [[ "$output" != *"Warning: preserved existing pre-commit hook:"* ]]
}

@test "setup removes obsolete path-obfuscation hook if present" {
  # Simulate upgrading from an old layout where path-obfuscation was installed
  cat > "$PARENT/.git/hooks/pre-commit.d/path-obfuscation" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$PARENT/.git/hooks/pre-commit.d/path-obfuscation"

  modules setup

  [ ! -e "$PARENT/.git/hooks/pre-commit.d/path-obfuscation" ]
}

@test "dispatcher runs hooks in pre-commit.d" {
  # Add a test hook that creates a marker file
  local marker="$BATS_TEST_TMPDIR/hook-ran"
  cat > "$PARENT/.git/hooks/pre-commit.d/test-hook" <<EOF
#!/usr/bin/env bash
touch "$marker"
EOF
  chmod +x "$PARENT/.git/hooks/pre-commit.d/test-hook"

  echo "test" > "$PARENT/testfile"
  git -C "$PARENT" add testfile
  git -C "$PARENT" commit -m "test commit"

  [ -f "$marker" ]
}

@test "dispatcher aborts commit on hook failure" {
  cat > "$PARENT/.git/hooks/pre-commit.d/always-fail" <<'EOF'
#!/usr/bin/env bash
echo "blocked" >&2
exit 1
EOF
  chmod +x "$PARENT/.git/hooks/pre-commit.d/always-fail"

  echo "test" > "$PARENT/testfile"
  git -C "$PARENT" add testfile
  run git -C "$PARENT" commit -m "should fail"
  [ "$status" -ne 0 ]
}

# ── gitmodules guard ───────────────────────────────────────────

@test "gitmodules guard rejects .gitmodules" {
  echo '[submodule "foo"]' > "$PARENT/.gitmodules"
  git -C "$PARENT" add .gitmodules

  run git -C "$PARENT" commit -m "add gitmodules"
  [ "$status" -ne 0 ]
  [[ "$output" == *".gitmodules"* ]]
}

@test "gitmodules guard allows normal commits" {
  echo "hello" > "$PARENT/normal-file.txt"
  git -C "$PARENT" add normal-file.txt

  run git -C "$PARENT" commit -m "normal commit"
  [ "$status" -eq 0 ]
}

# ── Manifest encryption guard ──────────────────────────────────

@test "manifest encryption hook warns without git-crypt" {
  # This simulates a manifest created by hand or by an older modules client.
  local fresh="$BATS_TEST_TMPDIR/no-git-crypt"
  create_parent_repo "$fresh"
  mkdir -p "$fresh/.git/hooks/pre-commit.d" "$fresh/.modules"
  cp "$REPO_DIR/hooks/dispatcher" "$fresh/.git/hooks/pre-commit"
  cp "$REPO_DIR/hooks/manifest-encryption" "$fresh/.git/hooks/pre-commit.d/manifest-encryption"
  chmod +x "$fresh/.git/hooks/pre-commit" "$fresh/.git/hooks/pre-commit.d/manifest-encryption"

  printf 'test\thttps://example.com/x.git\t0000000000000000000000000000000000000000\n' \
    > "$fresh/.modules/manifest"
  git -C "$fresh" add .modules/manifest

  run git -C "$fresh" commit -m "update manifest"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Run 'modules setup' to initialize encryption"* ]]
}
