#!/usr/bin/env bats
# merge-driver.bats — regression tests for the manifest merge driver.
#
# Simulates concurrent edits (the notes#48 bug class that motivated the
# redesign review) and asserts that the driver produces the right merge
# without corrupting the manifest.

bats_require_minimum_version 1.5.0

setup() {
  load test_helper

  PARENT="$BATS_TEST_TMPDIR/parent"
  REMOTE_A="$BATS_TEST_TMPDIR/remote_a"
  REMOTE_B="$BATS_TEST_TMPDIR/remote_b"

  create_remote_repo "$REMOTE_A"
  create_remote_repo "$REMOTE_B"
  create_parent_repo "$PARENT"
  export MODULES_CALLER_PWD="$PARENT"

  modules setup
  git -C "$PARENT" commit -m "init modules"

  # install-hooks writes 'modules merge-driver %O %A %B' so the command
  # resolves via PATH at merge time (avoids a stale absolute path on
  # upgrade). In tests, the shiv-installed `modules` on PATH is a stale
  # release version without the merge-driver task — rewrite the config to
  # point at the local driver script so tests exercise the in-tree code.
  git -C "$PARENT" config merge.modules-manifest.driver \
    "bash $REPO_DIR/lib/manifest-merge-driver.sh %O %A %B"
}

# ── Union merge (no conflicts) ─────────────────────────────────

@test "merge: two concurrent adds → both entries present (no conflict)" {
  # Set up a "main" with no modules. Branch off two feature branches,
  # each adding a different module, then merge them back.

  git -C "$PARENT" checkout -q -b branch-a
  modules add "$REMOTE_A" --name alpha
  git -C "$PARENT" commit -q -m "add alpha"

  git -C "$PARENT" checkout -q main
  git -C "$PARENT" checkout -q -b branch-b
  modules add "$REMOTE_B" --name beta
  git -C "$PARENT" commit -q -m "add beta"

  # Merge branch-a into branch-b. The manifest should union to both entries.
  git -C "$PARENT" merge --no-edit branch-a
  run git -C "$PARENT" status --porcelain
  # No unmerged markers expected
  [[ "$output" != *"UU"* ]]
  [[ "$output" != *"AA"* ]]

  # Both modules in manifest
  manifest_has_name "$PARENT/.modules/manifest" "alpha"
  manifest_has_name "$PARENT/.modules/manifest" "beta"
  run manifest_count_of "$PARENT/.modules/manifest"
  [ "$output" = "2" ]
}

@test "merge: concurrent pin bumps on different modules → both updated" {
  # Seed with two modules on main.
  modules add "$REMOTE_A" --name alpha
  modules add "$REMOTE_B" --name beta
  git -C "$PARENT" commit -q -m "seed modules"

  # Push new commits upstream on both remotes so 'modules update' has work to do.
  echo "a1" > "$REMOTE_A/a.md" && git -C "$REMOTE_A" add a.md && git -C "$REMOTE_A" commit -qm "a bump"
  echo "b1" > "$REMOTE_B/b.md" && git -C "$REMOTE_B" add b.md && git -C "$REMOTE_B" commit -qm "b bump"

  # Branch A bumps alpha, branch B bumps beta.
  git -C "$PARENT" checkout -q -b branch-a
  modules update alpha
  git -C "$PARENT" commit -q -m "bump alpha"

  git -C "$PARENT" checkout -q main
  git -C "$PARENT" checkout -q -b branch-b
  modules update beta
  git -C "$PARENT" commit -q -m "bump beta"

  # Merge.
  git -C "$PARENT" merge --no-edit branch-a

  # Both should have the bumped pins.
  local alpha_pin beta_pin alpha_expected beta_expected
  alpha_pin="$(manifest_pin_of "$PARENT/.modules/manifest" "alpha")"
  beta_pin="$(manifest_pin_of "$PARENT/.modules/manifest" "beta")"
  alpha_expected="$(git -C "$REMOTE_A" rev-parse HEAD)"
  beta_expected="$(git -C "$REMOTE_B" rev-parse HEAD)"
  [ "$alpha_pin" = "$alpha_expected" ]
  [ "$beta_pin" = "$beta_expected" ]

  # No leftover conflict markers
  run grep -c "<<<<<<<" "$PARENT/.modules/manifest"
  [ "$output" = "0" ]
}

@test "merge: concurrent same-module pin bumps choose descendant from ours" {
  modules add "$REMOTE_A" --name alpha
  git -C "$PARENT" commit -q -m "seed alpha"

  echo "v1" > "$REMOTE_A/v1.md"
  git -C "$REMOTE_A" add v1.md
  git -C "$REMOTE_A" commit -qm "v1"
  local v1
  v1="$(git -C "$REMOTE_A" rev-parse HEAD)"

  git -C "$PARENT" checkout -q -b branch-a
  modules update alpha
  [ "$(manifest_pin_of "$PARENT/.modules/manifest" "alpha")" = "$v1" ]
  git -C "$PARENT" commit -q -m "pin alpha to v1"

  echo "v2" > "$REMOTE_A/v2.md"
  git -C "$REMOTE_A" add v2.md
  git -C "$REMOTE_A" commit -qm "v2"
  local v2
  v2="$(git -C "$REMOTE_A" rev-parse HEAD)"

  git -C "$PARENT" checkout -q main
  git -C "$PARENT" checkout -q -b branch-b
  modules update alpha
  [ "$(manifest_pin_of "$PARENT/.modules/manifest" "alpha")" = "$v2" ]
  git -C "$PARENT" commit -q -m "pin alpha to v2"

  git -C "$PARENT" merge --no-edit branch-a

  [ "$(manifest_pin_of "$PARENT/.modules/manifest" "alpha")" = "$v2" ]
  run grep -c "<<<<<<<" "$PARENT/.modules/manifest"
  [ "$output" = "0" ]
}

@test "merge: concurrent same-module pin bumps choose descendant from theirs" {
  modules add "$REMOTE_A" --name alpha
  git -C "$PARENT" commit -q -m "seed alpha"

  echo "v1" > "$REMOTE_A/v1.md"
  git -C "$REMOTE_A" add v1.md
  git -C "$REMOTE_A" commit -qm "v1"
  local v1
  v1="$(git -C "$REMOTE_A" rev-parse HEAD)"

  git -C "$PARENT" checkout -q -b branch-a
  modules update alpha
  [ "$(manifest_pin_of "$PARENT/.modules/manifest" "alpha")" = "$v1" ]
  git -C "$PARENT" commit -q -m "pin alpha to v1"

  echo "v2" > "$REMOTE_A/v2.md"
  git -C "$REMOTE_A" add v2.md
  git -C "$REMOTE_A" commit -qm "v2"
  local v2
  v2="$(git -C "$REMOTE_A" rev-parse HEAD)"

  git -C "$PARENT" checkout -q main
  git -C "$PARENT" checkout -q -b branch-b
  modules update alpha
  [ "$(manifest_pin_of "$PARENT/.modules/manifest" "alpha")" = "$v2" ]
  git -C "$PARENT" commit -q -m "pin alpha to v2"

  git -C "$PARENT" checkout -q branch-a
  git -C "$PARENT" merge --no-edit branch-b

  [ "$(manifest_pin_of "$PARENT/.modules/manifest" "alpha")" = "$v2" ]
  run grep -c "<<<<<<<" "$PARENT/.modules/manifest"
  [ "$output" = "0" ]
}

@test "merge: delete on one side + unchanged on other → deletion accepted" {
  modules add "$REMOTE_A" --name alpha
  modules add "$REMOTE_B" --name beta
  git -C "$PARENT" commit -q -m "seed"

  git -C "$PARENT" checkout -q -b branch-a
  modules remove beta
  git -C "$PARENT" commit -q -m "drop beta"

  git -C "$PARENT" checkout -q main
  git -C "$PARENT" checkout -q -b branch-b
  echo "unrelated" > "$PARENT/unrelated.txt"
  git -C "$PARENT" add unrelated.txt
  git -C "$PARENT" commit -q -m "unrelated change"

  git -C "$PARENT" merge --no-edit branch-a

  # beta should be gone; alpha still present.
  manifest_has_name "$PARENT/.modules/manifest" "alpha"
  run manifest_has_name "$PARENT/.modules/manifest" "beta"
  [ "$status" -ne 0 ]
}

# ── Conflicts ──────────────────────────────────────────────────

# Helper: set a specific pin for a module via a direct manifest edit.
# Simulates the outcome of 'modules update' without having to choreograph
# upstream repos — the merge driver doesn't care how the pin got there.
set_pin() {
  local name="$1" pin="$2"
  awk -F'\t' -v n="$name" -v p="$pin" \
    'BEGIN { OFS="\t" } $1 == n { $3 = p } 1' \
    "$PARENT/.modules/manifest" > "$PARENT/.modules/manifest.tmp"
  mv "$PARENT/.modules/manifest.tmp" "$PARENT/.modules/manifest"
}

@test "merge: concurrent bumps of the same module → true conflict" {
  modules add "$REMOTE_A" --name alpha
  git -C "$PARENT" add .modules/manifest
  git -C "$PARENT" commit -q -m "seed"

  # Fake two different pins — don't need them to correspond to real commits;
  # the merge driver operates on the manifest text, not the submodule state.
  local v1="1111111111111111111111111111111111111111"
  local v2="2222222222222222222222222222222222222222"

  git -C "$PARENT" checkout -q -b branch-a
  set_pin alpha "$v1"
  git -C "$PARENT" add .modules/manifest
  git -C "$PARENT" commit -q -m "pin alpha to v1"

  git -C "$PARENT" checkout -q main
  git -C "$PARENT" checkout -q -b branch-b
  set_pin alpha "$v2"
  git -C "$PARENT" add .modules/manifest
  git -C "$PARENT" commit -q -m "pin alpha to v2"

  # Merge — should conflict.
  run git -C "$PARENT" merge --no-edit branch-a
  [ "$status" -ne 0 ]

  # Conflict markers should be in the manifest.
  run grep -c "<<<<<<< ours" "$PARENT/.modules/manifest"
  [ "$output" = "1" ]
  run grep -c ">>>>>>> theirs" "$PARENT/.modules/manifest"
  [ "$output" = "1" ]
}

@test "merge: both sides add same name with different urls → conflict" {
  # Two branches off of an empty manifest each add 'shared' pointing to
  # different repos. That's a real conflict.
  git -C "$PARENT" checkout -q -b branch-a
  modules add "$REMOTE_A" --name shared
  git -C "$PARENT" commit -q -m "add shared=A"

  git -C "$PARENT" checkout -q main
  git -C "$PARENT" checkout -q -b branch-b
  # modules/ is gitignored — branch-a's clone is still on disk. Remove it
  # before re-adding on this branch.
  rm -rf "$PARENT/modules/shared"
  modules add "$REMOTE_B" --name shared
  git -C "$PARENT" commit -q -m "add shared=B"

  run git -C "$PARENT" merge --no-edit branch-a
  [ "$status" -ne 0 ]

  run grep -c "<<<<<<<" "$PARENT/.modules/manifest"
  [ "$output" = "1" ]
}

# ── Integrity: the driver never produces corrupt JSON-style output ───

@test "merge: result is always valid TSV (sorted, 3 or 4 columns per line)" {
  modules add "$REMOTE_A" --name alpha
  modules add "$REMOTE_B" --name beta
  git -C "$PARENT" commit -q -m "seed"

  git -C "$PARENT" checkout -q -b branch-a
  # Remove one, add another
  modules remove beta
  local REMOTE_C="$BATS_TEST_TMPDIR/remote_c"
  create_remote_repo "$REMOTE_C"
  modules add "$REMOTE_C" --name gamma
  git -C "$PARENT" commit -q -m "drop beta, add gamma"

  git -C "$PARENT" checkout -q main
  git -C "$PARENT" checkout -q -b branch-b
  echo "noop" > "$PARENT/noop.txt" && git -C "$PARENT" add noop.txt
  git -C "$PARENT" commit -q -m "noop"

  git -C "$PARENT" merge --no-edit branch-a

  # All lines should have exactly 3 tab-separated fields, or 4 when a
  # tracking branch is present.
  local bad
  bad="$(awk -F'\t' 'NF != 3 && NF != 4' "$PARENT/.modules/manifest" || true)"
  [ -z "$bad" ]

  # Sorted by column 1
  local sorted
  sorted="$(sort -t$'\t' -k1,1 "$PARENT/.modules/manifest" | diff - "$PARENT/.modules/manifest" || true)"
  [ -z "$sorted" ]
}

@test "merge-driver re-encrypts successful git-crypt manifest output" {
  skip_unless_git_crypt

  local ancestor_plain="$BATS_TEST_TMPDIR/ancestor.txt"
  local ours_plain="$BATS_TEST_TMPDIR/ours.txt"
  local theirs_plain="$BATS_TEST_TMPDIR/theirs.txt"
  local ancestor_enc="$BATS_TEST_TMPDIR/ancestor.enc"
  local ours_enc="$BATS_TEST_TMPDIR/ours.enc"
  local theirs_enc="$BATS_TEST_TMPDIR/theirs.enc"
  local merged_plain="$BATS_TEST_TMPDIR/merged.txt"
  local expected="$BATS_TEST_TMPDIR/expected.txt"

  printf 'alpha\t%s\t%s\n' "$REMOTE_A" "$(repo_head "$REMOTE_A")" > "$ancestor_plain"
  cp "$ancestor_plain" "$ours_plain"
  printf 'beta\t%s\t%s\n' "$REMOTE_B" "$(repo_head "$REMOTE_B")" >> "$ours_plain"
  cp "$ancestor_plain" "$theirs_plain"
  printf 'gamma\t%s\t%s\n' "$REMOTE_B" "$(repo_head "$REMOTE_B")" >> "$theirs_plain"

  (cd "$PARENT" && git-crypt clean < "$ancestor_plain" > "$ancestor_enc")
  (cd "$PARENT" && git-crypt clean < "$ours_plain" > "$ours_enc")
  (cd "$PARENT" && git-crypt clean < "$theirs_plain" > "$theirs_enc")

  (cd "$PARENT" && bash "$REPO_DIR/lib/manifest-merge-driver.sh" "$ancestor_enc" "$ours_enc" "$theirs_enc")

  local header
  header="$(dd if="$ours_enc" bs=1 skip=1 count=8 2>/dev/null)"
  [ "$header" = "GITCRYPT" ]

  (cd "$PARENT" && git-crypt smudge < "$ours_enc" > "$merged_plain")
  {
    cat "$ancestor_plain"
    printf 'beta\t%s\t%s\n' "$REMOTE_B" "$(repo_head "$REMOTE_B")"
    printf 'gamma\t%s\t%s\n' "$REMOTE_B" "$(repo_head "$REMOTE_B")"
  } | sort -t$'\t' -k1,1 > "$expected"

  diff -u "$expected" "$merged_plain"
}

@test "merge-driver leaves current side intact when git-crypt clean fails" {
  local fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  local ancestor_plain="$BATS_TEST_TMPDIR/ancestor.txt"
  local ours_plain="$BATS_TEST_TMPDIR/ours.txt"
  local theirs_plain="$BATS_TEST_TMPDIR/theirs.txt"
  local ancestor_enc="$BATS_TEST_TMPDIR/ancestor.enc"
  local ours_enc="$BATS_TEST_TMPDIR/ours.enc"
  local theirs_enc="$BATS_TEST_TMPDIR/theirs.enc"
  local original_ours="$BATS_TEST_TMPDIR/original-ours.enc"

  mkdir -p "$fake_bin"
  cat > "$fake_bin/git-crypt" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  smudge) dd bs=1 skip=10 2>/dev/null ;;
  clean) exit 7 ;;
  *) exit 99 ;;
esac
EOF
  chmod +x "$fake_bin/git-crypt"

  printf 'alpha\t%s\t%s\n' "$REMOTE_A" "$(repo_head "$REMOTE_A")" > "$ancestor_plain"
  cp "$ancestor_plain" "$ours_plain"
  printf 'beta\t%s\t%s\n' "$REMOTE_B" "$(repo_head "$REMOTE_B")" >> "$ours_plain"
  cp "$ancestor_plain" "$theirs_plain"
  printf 'gamma\t%s\t%s\n' "$REMOTE_B" "$(repo_head "$REMOTE_B")" >> "$theirs_plain"

  { printf '\0GITCRYPT\0'; cat "$ancestor_plain"; } > "$ancestor_enc"
  { printf '\0GITCRYPT\0'; cat "$ours_plain"; } > "$ours_enc"
  { printf '\0GITCRYPT\0'; cat "$theirs_plain"; } > "$theirs_enc"
  cp "$ours_enc" "$original_ours"

  run env PATH="$fake_bin:$PATH" bash "$REPO_DIR/lib/manifest-merge-driver.sh" \
    "$ancestor_enc" "$ours_enc" "$theirs_enc"
  [ "$status" -ne 0 ]
  [[ "$output" == *"git-crypt clean failed"* ]]
  cmp "$original_ours" "$ours_enc"
}

# ── install-hooks task ─────────────────────────────────────────

@test "install-hooks registers merge driver in git config" {
  modules install-hooks

  run git -C "$PARENT" config --get merge.modules-manifest.driver
  [ "$status" -eq 0 ]
  # Resolves via PATH at merge time — no absolute path that can go stale.
  [[ "$output" == "modules merge-driver %O %A %B" ]]
}

@test "install-hooks: driver config does not embed an absolute path" {
  # Regression guard (RC-2 from peer review). An absolute path inside
  # $MISE_CONFIG_ROOT goes stale when shiv installs a new version to a
  # new directory, silently breaking the driver on upgrade.
  modules install-hooks

  run git -C "$PARENT" config --get merge.modules-manifest.driver
  [ "$status" -eq 0 ]
  [[ "$output" != *"/"* ]]
  [[ "$output" != *"$REPO_DIR"* ]]
}

@test "install-hooks adds merge attr to .gitattributes" {
  modules install-hooks

  run grep -F ".modules/manifest merge=modules-manifest" "$PARENT/.gitattributes"
  [ "$status" -eq 0 ]
}

@test "install-hooks is idempotent" {
  modules install-hooks
  modules install-hooks

  # Only one merge= entry in .gitattributes
  run grep -cF "merge=modules-manifest" "$PARENT/.gitattributes"
  [ "$output" = "1" ]
}

@test "setup installs merge driver by default" {
  # setup ran in the setup() function; driver should already be installed.
  # (Note: bats setup() rewrites the driver to a local path for test
  # isolation — check a fresh repo here to see what setup actually writes.)
  local fresh="$BATS_TEST_TMPDIR/fresh-parent"
  create_parent_repo "$fresh"
  MODULES_CALLER_PWD="$fresh" modules setup

  run git -C "$fresh" config --get merge.modules-manifest.driver
  [ "$status" -eq 0 ]
  [[ "$output" == "modules merge-driver %O %A %B" ]]
}

# ── End-to-end: production driver-resolution path ──────────────
#
# The setup() in this file rewrites the driver config to a direct
# `bash $REPO_DIR/lib/manifest-merge-driver.sh ...` invocation
# so the merge-logic tests don't depend on a `modules` shim being on
# PATH. That isolates the merge logic but leaves the production
# resolution path (`modules merge-driver %O %A %B` → PATH lookup →
# shiv shim → mise task → bash driver) unverified end-to-end.
#
# This test exercises the full path. It builds a temporary `modules`
# shim that hands off to the in-tree `mise run merge-driver`, prepends
# its directory to PATH, restores the production driver-config form,
# and runs a real concurrent-add merge. If `merge-driver` ever stops
# being a valid task, its USAGE contract drifts, or the install-hooks
# string drifts from `modules merge-driver %O %A %B`, this test fails.

@test "merge: production PATH-resolution path works end-to-end (modules merge-driver shim)" {
  # Build a `modules` shim that defers to the in-tree mise task. This
  # is the mechanic the shiv-installed shim uses in production.
  local shim_dir="$BATS_TEST_TMPDIR/path-shim"
  mkdir -p "$shim_dir"
  local shim_log="$BATS_TEST_TMPDIR/shim.log"
  # Mirror the production shiv shim's behavior: export MODULES_CALLER_PWD
  # (the user's original cwd, which git invoked the driver from) so the
  # merge-driver task can cd back to it before resolving the relative
  # %O %A %B paths.
  cat > "$shim_dir/modules" <<SHIM
#!/usr/bin/env bash
set -euo pipefail
echo "[shim] called: \$*" >> "$shim_log"
export MODULES_CALLER_PWD="\$PWD"
cd "$REPO_DIR"
exec mise run -q "\$@"
SHIM
  chmod +x "$shim_dir/modules"

  # Restore the production driver-config form (overriding the bypass
  # that setup() installed for the rest of this file's tests).
  git -C "$PARENT" config merge.modules-manifest.driver \
    "modules merge-driver %O %A %B"

  # Concurrent-add scenario: two branches independently add a module.
  # The merge result should union both, with no conflict markers.
  git -C "$PARENT" checkout -q -b branch-a
  modules add "$REMOTE_A" --name alpha
  git -C "$PARENT" commit -q -m "add alpha"

  git -C "$PARENT" checkout -q main
  git -C "$PARENT" checkout -q -b branch-b
  modules add "$REMOTE_B" --name beta
  git -C "$PARENT" commit -q -m "add beta"

  # The bats test_helper exports a `modules` bash function that
  # shadows PATH lookup whenever git's `sh -c` is bash-compatible.
  # Unset the function so PATH wins and the shim gets called — this
  # is the whole point of the test.
  unset -f modules

  # Pin the resolution to our shim. If test_helper.bash ever changes
  # how it shadows `modules` (e.g., switches to its own PATH-based
  # shim), this assertion catches the drift before the merge step
  # silently exercises the wrong binary.
  PATH="$shim_dir:$PATH" run command -v modules
  [ "$status" -eq 0 ]
  [ "$output" = "$shim_dir/modules" ]

  # Merge with the shim on PATH so the `modules` config string resolves.
  PATH="$shim_dir:$PATH" git -C "$PARENT" merge --no-edit branch-a

  # Sanity: the shim must have been invoked. If it wasn't, git silently
  # fell back to the default merge driver — the exact failure mode this
  # test exists to catch.
  [ -s "$shim_log" ]
  grep -q '\[shim\] called: merge-driver' "$shim_log"

  manifest_has_name "$PARENT/.modules/manifest" "alpha"
  manifest_has_name "$PARENT/.modules/manifest" "beta"
  run manifest_count_of "$PARENT/.modules/manifest"
  [ "$output" = "2" ]
  run grep -c "<<<<<<<" "$PARENT/.modules/manifest"
  [ "$output" = "0" ]
}
