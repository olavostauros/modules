#!/usr/bin/env bash
# manifest-merge-driver.sh — custom git merge driver for .modules/manifest
#
# Git calls this with: %O %A %B (ancestor, ours, theirs).
# Writes the merged result to %A. Exit 0 on success, non-zero on conflict.
#
# Manifest format: <name>\t<url>\t<pin>[\t<track>], one per line, sorted by name.
#
# Strategy: union merge keyed on name.
# - Same name, same url+pin on both sides → take it.
# - Same name, one side unchanged from ancestor, other side updated → take the update.
# - Same name, both sides changed values differently → CONFLICT.
# - Name present in ancestor but deleted on one side and unchanged on the
#   other → accept the deletion.
# - Name present in ancestor, deleted on one side, modified on the other →
#   CONFLICT (hard to know intent).
# - Name new on one side only → include it.
# - Name new on both sides with same value → include it.
# - Name new on both sides with different values → CONFLICT.
#
# Adapted from KnickKnackLabs/notes' manifest-merge-driver.sh. Schema
# differs (3+ optional tracking cols vs 2); key is col 1 (name) in both,
# but notes has (obfuscated-id, readable-name) and we have (name, url, pin,
# optional track).
#
# Bash 3.2 compatible.
set -eo pipefail

ANCESTOR="$1"  # %O — common ancestor
OURS="$2"      # %A — current branch (merge result goes here)
THEIRS="$3"    # %B — branch being merged

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Git invokes merge drivers with index content. For git-crypt-tracked files,
# that content is the encrypted ciphertext (starts with "\0GITCRYPT\0"). We
# need plaintext to merge. If the file is encrypted, decrypt via git-crypt's
# smudge filter. If smudge fails (repo locked, git-crypt missing), abort —
# producing a corrupt merged manifest silently would be much worse than
# leaving git to raise a conflict.
is_gitcrypt_file() {
  local src="$1"
  [ -s "$src" ] || return 1
  # git-crypt files begin with \0 G I T C R Y P T \0 (10 bytes).
  # Bash strings can't carry a leading \0 — read bytes 2-9 and check for "GITCRYPT".
  local header
  header=$(dd if="$src" bs=1 skip=1 count=8 2>/dev/null)
  [ "$header" = "GITCRYPT" ]
}

decrypt_if_needed() {
  local src="$1" dst="$2"
  if [ ! -s "$src" ]; then
    : > "$dst"
    return 0
  fi
  if is_gitcrypt_file "$src"; then
    if ! git-crypt smudge < "$src" > "$dst" 2>/dev/null; then
      echo "modules manifest-merge-driver: git-crypt smudge failed on $src — is the repo unlocked?" >&2
      echo "modules manifest-merge-driver: aborting merge to avoid producing a corrupt manifest." >&2
      return 1
    fi
  else
    cp "$src" "$dst"
  fi
}

write_success_result() {
  local plaintext="$1"
  if is_gitcrypt_file "$ANCESTOR" || is_gitcrypt_file "$OURS" || is_gitcrypt_file "$THEIRS"; then
    local ours_dir ours_base cleaned
    ours_dir=$(dirname "$OURS")
    ours_base=$(basename "$OURS")
    cleaned=$(mktemp "$ours_dir/.${ours_base}.clean.XXXXXX") || return 1
    if ! git-crypt clean < "$plaintext" > "$cleaned" 2>/dev/null; then
      rm -f "$cleaned"
      echo "modules manifest-merge-driver: git-crypt clean failed — is this a git-crypt repo?" >&2
      echo "modules manifest-merge-driver: aborting merge to avoid committing a plaintext manifest." >&2
      return 1
    fi
    mv "$cleaned" "$OURS"
  else
    cp "$plaintext" "$OURS"
  fi
}

# Normalize: decrypt if encrypted, strip blank lines, sort by name.
normalize() {
  local src="$1" plaintext
  plaintext=$(mktemp "$WORK/plain.XXXXXX")
  decrypt_if_needed "$src" "$plaintext" || return 1
  awk 'NF' "$plaintext" | sort -t$'\t' -k1,1
}

normalize "$ANCESTOR" > "$WORK/anc"
normalize "$OURS"     > "$WORK/ours"
normalize "$THEIRS"   > "$WORK/theirs"

manifest_value_for_name() {
  local file="$1" name="$2"
  awk -F'\t' -v wanted="$name" '
    NF >= 3 && $1 == wanted { print substr($0, index($0, "\t") + 1); found=1; exit }
    END { exit found ? 0 : 1 }
  ' "$file"
}

manifest_value_field() {
  local value="$1" field="$2"
  printf '%s\n' "$value" | awk -F'\t' -v field="$field" '{ print $field; exit }'
}

manifest_value_field_count() {
  local value="$1"
  printf '%s\n' "$value" | awk -F'\t' '{ print NF; exit }'
}

module_clone_dir() {
  local name="$1" configured=""
  if [ -f ".modules/config" ] && command -v jq >/dev/null 2>&1; then
    if configured=$(jq -r '.path // empty' .modules/config 2>/dev/null); then
      [ -n "$configured" ] || configured="modules"
    else
      configured="modules"
    fi
  else
    configured="modules"
  fi
  printf '%s/%s\n' "$configured" "$name"
}

module_pin_is_ancestor() {
  local name="$1" older="$2" newer="$3" expected_url="$4" clone_dir actual_url
  clone_dir=$(module_clone_dir "$name")

  if ! git -C "$clone_dir" rev-parse --git-dir >/dev/null 2>&1; then
    return 1
  fi
  if ! actual_url=$(git -C "$clone_dir" remote get-url origin 2>/dev/null); then
    return 1
  fi
  if [ "$actual_url" != "$expected_url" ]; then
    return 1
  fi
  if ! git -C "$clone_dir" cat-file -e "${older}^{commit}" 2>/dev/null; then
    return 1
  fi
  if ! git -C "$clone_dir" cat-file -e "${newer}^{commit}" 2>/dev/null; then
    return 1
  fi
  git -C "$clone_dir" merge-base --is-ancestor "$older" "$newer" >/dev/null 2>&1
}

# Compute the sorted-unique union of names across all three sides. Use
# `NF >= 3` to filter corrupt/partial rows; cut -f1 would emit the
# whole line for rows lacking tabs and produce phantom names downstream.
{
  awk -F'\t' 'NF >= 3 {print $1}' "$WORK/anc"    2>/dev/null
  awk -F'\t' 'NF >= 3 {print $1}' "$WORK/ours"   2>/dev/null
  awk -F'\t' 'NF >= 3 {print $1}' "$WORK/theirs" 2>/dev/null
} | sort -u > "$WORK/all_names"

# Pre-resolve same-module pin bumps when both sides changed the pin and one
# pin is provably an ancestor of the other in the matching local module clone.
# If the clone is missing, its origin URL does not match the manifest URL,
# commits are missing, URL/track metadata differs, or the histories diverged,
# leave the row unresolved so the normal conflict path fires. Merge drivers
# should not fetch or guess.
: > "$WORK/descendant_resolutions"
while IFS= read -r name; do
  [ -n "$name" ] || continue

  a_value=$(manifest_value_for_name "$WORK/anc" "$name") && a_set=true || a_set=false
  o_value=$(manifest_value_for_name "$WORK/ours" "$name") && o_set=true || o_set=false
  t_value=$(manifest_value_for_name "$WORK/theirs" "$name") && t_set=true || t_set=false

  if ! $a_set || ! $o_set || ! $t_set; then
    continue
  fi
  if [ "$o_value" = "$t_value" ] || [ "$o_value" = "$a_value" ] || [ "$t_value" = "$a_value" ]; then
    continue
  fi

  o_fields=$(manifest_value_field_count "$o_value")
  t_fields=$(manifest_value_field_count "$t_value")
  if { [ "$o_fields" -ne 2 ] && [ "$o_fields" -ne 3 ]; } \
    || { [ "$t_fields" -ne 2 ] && [ "$t_fields" -ne 3 ]; }; then
    continue
  fi

  o_url=$(manifest_value_field "$o_value" 1)
  o_pin=$(manifest_value_field "$o_value" 2)
  o_track=$(manifest_value_field "$o_value" 3)
  t_url=$(manifest_value_field "$t_value" 1)
  t_pin=$(manifest_value_field "$t_value" 2)
  t_track=$(manifest_value_field "$t_value" 3)

  if [ "$o_url" != "$t_url" ] || [ "$o_track" != "$t_track" ]; then
    continue
  fi

  if module_pin_is_ancestor "$name" "$t_pin" "$o_pin" "$o_url"; then
    printf '%s\t%s\n' "$name" "$o_value" >> "$WORK/descendant_resolutions"
  elif module_pin_is_ancestor "$name" "$o_pin" "$t_pin" "$o_url"; then
    printf '%s\t%s\n' "$name" "$t_value" >> "$WORK/descendant_resolutions"
  fi
done < "$WORK/all_names"

: > "$WORK/merged"
: > "$WORK/conflicts"

# Single-pass merge: load all three sides into awk arrays keyed by name,
# then iterate the pre-sorted union once. Replaces the previous bash
# read-loop that walked each side per name (O(N²) per merge).
#
# Awk exit status: 0 = clean merge, 1 = conflict, anything else = awk
# failure (programmer error or environmental). The bash wrapper reads
# this and either appends conflict markers or exits with the failure.
set +e
awk -F'\t' \
    -v MERGED="$WORK/merged" \
    -v CONFLICTS="$WORK/conflicts" \
    -v ALLNAMES="$WORK/all_names" \
    -v ANCFILE="$WORK/anc" \
    -v OURSFILE="$WORK/ours" \
    -v THEIRSFILE="$WORK/theirs" \
    -v RESFILE="$WORK/descendant_resolutions" '
  BEGIN { OFS = "\t"; conflict = 0 }

  # Filter corrupt/partial rows the same way the union collection above
  # does so a row without a value cannot leak a name into the merge.
  NF < 3 { next }

  # Route each input row to the right side via FILENAME comparison.
  # An FNR==1 counter would skip empty files (the ancestor is empty on
  # a first-commit merge), shifting the index and routing rows wrong.
  # Store everything-after-the-first-tab as the value (cols 2-3 joined);
  # `index($0, "\t")` positions on the actual delimiter byte so
  # multi-byte names stay correct (defense in depth; manifest names are
  # ASCII today).
  #
  # Note: for a *malformed* input with duplicate-name rows, the array
  # assignment is last-wins (the previous bash `value_for_name` was
  # first-wins). The manifest invariant guarantees one entry per name,
  # so this only matters as archaeology if a corrupt manifest is fed
  # in; in that case neither behavior is more correct than the other.
  FILENAME == RESFILE    { resolved[$1] = substr($0, index($0, "\t") + 1); has_resolved[$1] = 1; next }
  FILENAME == ANCFILE    { anc[$1]    = substr($0, index($0, "\t") + 1); has_anc[$1]    = 1 }
  FILENAME == OURSFILE   { ours[$1]   = substr($0, index($0, "\t") + 1); has_ours[$1]   = 1 }
  FILENAME == THEIRSFILE { theirs[$1] = substr($0, index($0, "\t") + 1); has_theirs[$1] = 1 }

  END {
    # Iterate the union in sorted order. POSIX awk lacks asort();
    # read the pre-sorted unique-names file via getline instead.
    while ((getline name < ALLNAMES) > 0) {
      if (name == "") continue
      a_set = (name in has_anc)
      o_set = (name in has_ours)
      t_set = (name in has_theirs)
      a = anc[name]; o = ours[name]; t = theirs[name]

      if (o_set && t_set) {
        if (o == t) {
          # Same on both sides — take it.
          print name OFS o > MERGED
        } else if (name in has_resolved) {
          # Both sides bumped the same module pin, and the bash pre-pass
          # proved one pin descends from the other in the local clone.
          print name OFS resolved[name] > MERGED
        } else if (!a_set) {
          # Both sides added the name with different values — conflict.
          emit_conflict(name, o, t, "ours", "theirs")
          conflict = 1
        } else if (o == a) {
          # Ours unchanged from ancestor, theirs updated — take theirs.
          print name OFS t > MERGED
        } else if (t == a) {
          # Theirs unchanged from ancestor, ours updated — take ours.
          print name OFS o > MERGED
        } else {
          # Both diverged from ancestor in different ways — conflict.
          emit_conflict(name, o, t, "ours", "theirs")
          conflict = 1
        }
      } else if (o_set && !t_set) {
        if (a_set && o == a) {
          # Theirs deleted it; ours unchanged — accept deletion.
        } else if (a_set) {
          # Theirs deleted it; ours modified it — modify-vs-delete conflict.
          emit_md_conflict(name, o, "ours (modified)", "theirs", "deleted in theirs")
          conflict = 1
        } else {
          # New in ours only — keep.
          print name OFS o > MERGED
        }
      } else if (!o_set && t_set) {
        if (a_set && t == a) {
          # Ours deleted it; theirs unchanged — accept deletion.
        } else if (a_set) {
          # Ours deleted it; theirs modified — conflict.
          emit_dm_conflict(name, t, "ours", "deleted in ours", "theirs (modified)")
          conflict = 1
        } else {
          # New in theirs only — keep.
          print name OFS t > MERGED
        }
      }
      # Neither set: cannot happen; the name came from the union.
    }
    close(MERGED)
    close(CONFLICTS)
    exit conflict
  }

  # Standard 3-way conflict block (both sides have the name with values).
  function emit_conflict(name, o_val, t_val, ours_label, theirs_label) {
    print "<<<<<<< " ours_label   > CONFLICTS
    print name OFS o_val          > CONFLICTS
    print "======="               > CONFLICTS
    print name OFS t_val          > CONFLICTS
    print ">>>>>>> " theirs_label > CONFLICTS
  }

  # Modify-on-ours vs delete-on-theirs.
  function emit_md_conflict(name, o_val, ours_label, theirs_label, theirs_body) {
    print "<<<<<<< " ours_label   > CONFLICTS
    print name OFS o_val          > CONFLICTS
    print "======="               > CONFLICTS
    print "(" theirs_body ")"     > CONFLICTS
    print ">>>>>>> " theirs_label > CONFLICTS
  }

  # Delete-on-ours vs modify-on-theirs.
  function emit_dm_conflict(name, t_val, ours_label, ours_body, theirs_label) {
    print "<<<<<<< " ours_label   > CONFLICTS
    print "(" ours_body ")"       > CONFLICTS
    print "======="               > CONFLICTS
    print name OFS t_val          > CONFLICTS
    print ">>>>>>> " theirs_label > CONFLICTS
  }
' "$WORK/descendant_resolutions" "$WORK/anc" "$WORK/ours" "$WORK/theirs"
awk_status=$?
set -e

case "$awk_status" in
  0) has_conflict=false ;;
  1) has_conflict=true ;;
  *)
    echo "modules manifest-merge-driver: awk merge failed (status $awk_status) — aborting merge" >&2
    exit 2
    ;;
esac

# all_names is already sorted, and the awk pass emits in the same order,
# so $WORK/merged is sorted by construction. Sort once more as a
# defense-in-depth pass in case a future awk change reorders.
sort -t$'\t' -k1,1 "$WORK/merged" > "$WORK/result"

if [ "$has_conflict" = true ]; then
  cp "$WORK/result" "$OURS"
  cat "$WORK/conflicts" >> "$OURS"
  exit 1
fi

write_success_result "$WORK/result"
exit 0
