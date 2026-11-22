#!/bin/bash
# Test suite for ./hosts. Every test works on a throwaway hosts file in a temp
# folder (HOSTS_FILE / HOSTS_SETS_DIR / NO_SUDO=1) — the real /etc/hosts is never touched.
#
#   tests/run.sh            run everything
#   tests/run.sh import     run only tests whose name contains "import"

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOSTS="$ROOT/hosts"
FIXTURES="$ROOT/tests/fixtures"
FILTER="${1:-}"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
export NO_SUDO=1 TMPDIR="$SCRATCH/tmp/"
mkdir -p "$TMPDIR"

pass=0 fail=0 current=""
LOCALHOST=$'127.0.0.1\tlocalhost'

# --- helpers -----------------------------------------------------------------

# Fresh test folder; $T is the folder, hosts file starts as just localhost.
fresh() {
  T="$SCRATCH/$current"; rm -rf "$T"; mkdir -p "$T/sets"
  echo "$LOCALHOST" > "$T/hosts"
  export HOSTS_FILE="$T/hosts" HOSTS_SETS_DIR="$T/sets"
  [ "$HOSTS_FILE" != /etc/hosts ] || { echo "refusing to test against /etc/hosts"; exit 2; }
}
h()          { "$HOSTS" "$@"; }
fail()       { echo "    ✗ $*"; failed=1; }
check()      { "$@" || fail "expected: $*"; }
contains()   { grep -qF -- "$2" "$1" || fail "$1 should contain: $2"; }
lacks()      { ! grep -qF -- "$2" "$1" || fail "$1 should not contain: $2"; }
count()      { local n; n=$(grep -cF -- "$2" "$1" || true); [ "$n" = "$3" ] || fail "$1: expected $3 × '$2', got $n"; }
same_file()  { cmp -s "$1" "$2" || fail "$1 and $2 differ"; }
entries()    { grep -vE '^[[:space:]]*(#|$)' "$1" | sort; }
same_entries() { diff <(entries "$1") <(entries "$2") >/dev/null || fail "active entries differ between $1 and $2"; }
says()       { local out; out="$("$HOSTS" "${@:2}")"; [[ "$out" == *"$1"* ]] || fail "'hosts ${*:2}' should say: $1"; }
set_on()     { local out; out="$(h list)"; grep -q "on .* $1\$" <<<"$out" || fail "'$1' should be on"; }
set_off()    { local out; out="$(h list)"; grep -q "off.* $1\$" <<<"$out" || fail "'$1' should be off"; }

run() {
  current="$1"
  [ -z "$FILTER" ] || [[ "$current" == *"$FILTER"* ]] || return 0
  failed=0
  "test_$current" >"$SCRATCH/$current.log" 2>&1 || fail "exited with status $?"
  if [ $failed = 0 ]; then pass=$((pass + 1)); echo "  ✓ $current"
  else fail=$((fail + 1)); echo "  ✗ $current"; sed 's/^/      /' "$SCRATCH/$current.log"; fi
}

# --- basics ------------------------------------------------------------------

test_list_empty() { fresh; says "No sets yet" list; }

test_on_off() {
  fresh
  echo "10.0.0.1 one.test" > "$T/sets/one.hosts"
  h on one; contains "$T/hosts" "10.0.0.1 one.test"; set_on one
  h off one; lacks "$T/hosts" "one.test"; set_off one
  same_file "$T/hosts" <(echo "$LOCALHOST")
}

test_on_twice_keeps_one_copy() {
  fresh
  echo "10.0.0.1 one.test" > "$T/sets/one.hosts"
  h on one; h on one
  count "$T/hosts" "one.test" 1
}

test_off_when_already_off() {
  fresh; echo "10.0.0.1 one.test" > "$T/sets/one.hosts"
  says "already off" off one
  check [ -z "$(ls -A "$T/sets/.backups" 2>/dev/null)" ]
}

test_unknown_and_bad_names() {
  fresh
  ! h on nope 2>/dev/null; check [ $? = 0 ]
  ! h on "a b" 2>/dev/null; check [ $? = 0 ]
  ! h on "../x" 2>/dev/null; check [ $? = 0 ]
  ! h bogus 2>/dev/null; check [ $? = 0 ]
}

test_delete() {
  fresh; echo "10.0.0.1 one.test" > "$T/sets/one.hosts"
  h on one; h delete one
  lacks "$T/hosts" "one.test"; check [ ! -e "$T/sets/one.hosts" ]
}

test_refuses_without_localhost() {
  fresh; echo "10.0.0.1 one.test" > "$T/sets/one.hosts"
  echo "# empty" > "$T/hosts"; cp "$T/hosts" "$T/before"
  ! h on one 2>/dev/null; check [ $? = 0 ]
  same_file "$T/hosts" "$T/before"
}

test_version_and_help() {
  fresh
  says "hosts dev" version
  says "hosts on NAME" help
}

# --- robustness (each of these was a real bug found in review) ---------------

test_set_without_trailing_newline() {
  fresh
  printf '10.0.0.1 a.test' > "$T/sets/a.hosts"
  echo "10.0.0.2 b.test" > "$T/sets/b.hosts"
  h on a; h on b; h off a
  contains "$T/hosts" "10.0.0.2 b.test"; set_on b; set_off a
}

test_damaged_end_marker_is_refused() {
  fresh; echo "10.0.0.2 b.test" > "$T/sets/b.hosts"; h on b
  sed -i '' 's/^# <<< hosts-set:b$/# <<< hosts-set:b oops/' "$T/hosts"
  echo "10.9.9.9 after.test" >> "$T/hosts"; cp "$T/hosts" "$T/before"
  ! h off b 2>/dev/null; check [ $? = 0 ]
  same_file "$T/hosts" "$T/before"
}

test_marker_lines_inside_a_set_are_ignored() {
  fresh
  printf '10.0.0.1 x.test\n# <<< hosts-set:x\n' > "$T/sets/x.hosts"
  h on x; count "$T/hosts" "# <<< hosts-set:x" 1
  h off x; same_file "$T/hosts" <(echo "$LOCALHOST")
}

test_backups_same_second_and_restore() {
  fresh
  echo "10.0.0.1 d.test" > "$T/sets/d.hosts"; echo "10.0.0.2 e.test" > "$T/sets/e.hosts"
  h on d; h on e
  check [ "$(ls "$T/sets/.backups" | wc -l | tr -d ' ')" = 2 ]
  echo y | h restore; lacks "$T/hosts" "e.test"; contains "$T/hosts" "d.test"
  echo y | h restore; contains "$T/hosts" "e.test"     # restore can be undone
}

test_backups_are_pruned_to_20() {
  fresh; echo "10.0.0.1 d.test" > "$T/sets/d.hosts"
  for _ in $(seq 1 25); do h on d >/dev/null; done
  check [ "$(ls "$T/sets/.backups" | wc -l | tr -d ' ')" = 20 ]
}

test_restore_cancel_and_eof() {
  fresh; echo "10.0.0.1 d.test" > "$T/sets/d.hosts"; h on d; cp "$T/hosts" "$T/before"
  echo n | says cancelled restore
  says cancelled restore </dev/null
  same_file "$T/hosts" "$T/before"
}

test_editor_with_spaces_and_options() {
  fresh
  local ed="$T/My Editor/ed"; mkdir -p "$T/My Editor"
  printf '#!/bin/sh\n[ "$1" = -w ] && shift\necho "10.0.0.8 ed.test" >> "$1"\n' > "$ed"; chmod +x "$ed"
  EDITOR="$ed" h edit x                    # plain path containing a space
  EDITOR="'$ed' -w" h edit x               # quoted path plus an option
  count "$T/sets/x.hosts" "ed.test" 2
  h on x; EDITOR="$ed" h edit x            # editing a set that's on re-applies it
  count "$T/hosts" "ed.test" 3
}

test_no_temp_files_left_behind() {
  fresh; cp "$FIXTURES/ihosts-sample" "$T/hosts"
  h import </dev/null >/dev/null
  echo "10.0.0.1 d.test" > "$T/sets/d.hosts"; h on d 2>/dev/null || true
  check [ -z "$(ls "$TMPDIR")" ]
}

# --- import ------------------------------------------------------------------

test_import_sample() {
  fresh; cp "$FIXTURES/ihosts-sample" "$T/hosts"; cp "$T/hosts" "$T/original"
  echo y | h import
  for s in development staging local-stack; do set_on "$s"; done
  same_entries "$T/hosts" "$T/original"
  contains "$T/sets/development.hosts" "#Archived"           # comments kept
  contains "$T/sets/staging.hosts" "#10.0.0.5 disabled.example.com"
  lacks "$T/hosts" "# ----"                                  # iHosts layout gone
}

test_import_round_trip() {
  fresh; cp "$FIXTURES/ihosts-sample" "$T/hosts"; cp "$T/hosts" "$T/original"
  echo y | h import
  for s in development staging local-stack; do h off "$s"; done
  same_entries "$T/hosts" <(echo "$LOCALHOST"; printf '255.255.255.255\tbroadcasthost\n::1             localhost\n')
  check [ -n "$(tail -1 "$T/hosts")" ]                       # no trailing blank lines
  for s in development staging local-stack; do h on "$s"; done
  same_entries "$T/hosts" "$T/original"
}

test_import_twice_is_refused() {
  fresh; cp "$FIXTURES/ihosts-sample" "$T/hosts"
  echo y | h import
  ! h import 2>/dev/null; check [ $? = 0 ]
}

test_import_cancel_changes_nothing() {
  fresh; cp "$FIXTURES/ihosts-sample" "$T/hosts"; cp "$T/hosts" "$T/before"
  echo n | says cancelled import
  same_file "$T/hosts" "$T/before"; check [ -z "$(ls "$T/sets"/*.hosts 2>/dev/null)" ]
}

test_import_failed_write_saves_nothing() {
  fresh; cp "$FIXTURES/ihosts-sample" "$T/hosts"; chmod 444 "$T/hosts"
  ! (echo y | h import >/dev/null 2>&1); check [ $? = 0 ]
  check [ -z "$(ls "$T/sets"/*.hosts 2>/dev/null)" ]
  chmod 644 "$T/hosts"
  echo y | says Imported import   # can simply be re-run
}

test_import_duplicate_names() {
  fresh
  local D='# ----------' G='# =========='
  printf "$D\n# Default\n$LOCALHOST\n$G\n# G1\n$D\n# Test\n10.0.0.4 x.test\n$G\n# G2\n$D\n# Test\n10.0.0.5 y.test\n$D\n# Test\n10.0.0.6 z.test\n$D\n# Empty\n\n$D\n# 日本\n10.0.0.7 j.test\n" > "$T/hosts"
  echo y | h import
  contains "$T/sets/test.hosts" "x.test";    lacks "$T/sets/test.hosts" "y.test"
  contains "$T/sets/g2-test.hosts" "y.test"; contains "$T/sets/g2-test-2.hosts" "z.test"
  contains "$T/sets/set.hosts" "j.test";     check [ ! -e "$T/sets/empty.hosts" ]
}

test_import_rejects_non_ihosts_file() {
  fresh
  ! h import 2>/dev/null; check [ $? = 0 ]
}

# --- lines added by other programs -------------------------------------------

# Imported sample, then "an installer" appends its own lines outside any set.
installer_adds() {
  fresh; cp "$FIXTURES/ihosts-sample" "$T/hosts"; echo y | h import >/dev/null
  printf '\n# Added by devenv\n127.0.0.1\tproj.example.dev\n127.0.0.1\tapi.proj.example.dev\n' >> "$T/hosts"
}

test_changes_none_after_import() {
  fresh; cp "$FIXTURES/ihosts-sample" "$T/hosts"; echo y | h import >/dev/null
  says "No changes outside your sets" changes
  local out; out="$(h list)"; [[ "$out" != *"outside your sets"* ]] || fail "list shouldn't warn"
}

test_changes_spots_added_lines() {
  installer_adds
  says "+ 127.0.0.1	proj.example.dev" changes
  says "2 entries added" list
  says "hosts adopt NAME" list
}

test_changes_spots_removed_lines() {
  installer_adds; h keep >/dev/null
  sed -i '' '/^255.255.255.255/d' "$T/hosts"
  says "- 255.255.255.255	broadcasthost" changes
}

test_changes_ignore_spacing_and_set_contents() {
  fresh; echo "10.0.0.1 one.test" > "$T/sets/one.hosts"; h on one
  printf '127.0.0.1    localhost\n' > "$T/hosts.new"           # same line, different spacing
  sed -n '2,$p' "$T/hosts" >> "$T/hosts.new"; mv "$T/hosts.new" "$T/hosts"
  says "No changes outside your sets" changes
}

test_adopt_new_set() {
  installer_adds; cp "$T/hosts" "$T/before"
  h adopt devenv
  set_on devenv
  contains "$T/sets/devenv.hosts" "proj.example.dev"
  contains "$T/sets/devenv.hosts" "# Added by devenv"          # comments come along
  count "$T/hosts" "proj.example.dev" 2                         # proj + api.proj, once each
  same_entries "$T/hosts" "$T/before"                           # nothing resolves differently
  says "No changes outside your sets" changes
  h off devenv; lacks "$T/hosts" "proj.example.dev"
  for s in development staging local-stack; do set_on "$s"; done  # other sets untouched
}

test_adopt_off() {
  installer_adds
  h adopt devenv --off
  set_off devenv; lacks "$T/hosts" "proj.example.dev"
  contains "$T/sets/devenv.hosts" "api.proj.example.dev"
  says "No changes outside your sets" changes
}

test_adopt_into_existing_set_dedupes() {
  installer_adds; h adopt devenv >/dev/null
  printf '127.0.0.1 proj.example.dev\n127.0.0.1 new.example.dev\n' >> "$T/hosts"   # installer runs again
  h adopt devenv
  check [ "$(grep -cE '^127\.0\.0\.1[[:space:]]+proj\.example\.dev$' "$T/sets/devenv.hosts")" = 1 ]
  count "$T/sets/devenv.hosts" "new.example.dev" 1
  count "$T/hosts" "new.example.dev" 1
  says "No changes outside your sets" changes
}

test_adopt_while_set_off_keeps_it_off_with_flag() {
  installer_adds; h adopt devenv >/dev/null; h off devenv >/dev/null
  printf '127.0.0.1 proj.example.dev\n' >> "$T/hosts"                            # installer re-adds
  h adopt devenv --off
  set_off devenv; lacks "$T/hosts" "proj.example.dev"
}

test_adopt_nothing_to_adopt() {
  fresh; cp "$FIXTURES/ihosts-sample" "$T/hosts"; echo y | h import >/dev/null; cp "$T/hosts" "$T/before"
  says "No new entries" adopt devenv
  check [ ! -e "$T/sets/devenv.hosts" ]; same_file "$T/hosts" "$T/before"
}

test_adopt_bad_args() {
  installer_adds; cp "$T/hosts" "$T/before"
  ! h adopt 2>/dev/null; check [ $? = 0 ]
  ! h adopt a b 2>/dev/null; check [ $? = 0 ]
  ! h adopt "bad name" 2>/dev/null; check [ $? = 0 ]
  same_file "$T/hosts" "$T/before"
}

test_adopt_failed_write_changes_nothing() {
  installer_adds; chmod 444 "$T/hosts"
  ! h adopt devenv >/dev/null 2>&1; check [ $? = 0 ]
  check [ ! -e "$T/sets/devenv.hosts" ]
  chmod 644 "$T/hosts"; says "2 entries added" list           # still flagged, can retry
}

test_keep() {
  installer_adds; cp "$T/hosts" "$T/before"
  says "Kept" keep
  same_file "$T/hosts" "$T/before"                              # keep never rewrites hosts
  says "No changes outside your sets" changes
}

test_on_off_dont_swallow_added_lines() {
  installer_adds
  h off staging >/dev/null; h on staging >/dev/null
  says "2 entries added" list                                   # still flagged, not absorbed
  contains "$T/hosts" "proj.example.dev"
}

# --- damage and repair -------------------------------------------------------
#
# Each scenario starts from the imported sample with 'staging' switched off,
# damages the file the way a misbehaving installer might, then checks that:
#   check fails · repair restores the same on/off states and a healthy file ·
#   lines the "installer" added survive (and are still flagged) · a second repair does nothing.

healthy_start() {
  fresh; cp "$FIXTURES/ihosts-sample" "$T/hosts"; echo y | h import >/dev/null; h off staging >/dev/null
}
FOREIGN="127.0.0.1 proj.example.dev"

repaired_ok() {   # $1 = 1 if the installer's line should have survived
  ! h check >/dev/null 2>&1; check [ $? = 0 ]
  echo y | h repair || fail "repair failed"
  says "No problems found" check
  set_on development; set_on local-stack; set_off staging
  contains "$T/hosts" $'127.0.0.1\tlocalhost'
  contains "$T/hosts" "site-one.test"; contains "$T/hosts" "app.example.dev"; lacks "$T/hosts" "203.0.113.10"
  if [ "${1:-0}" = 1 ]; then contains "$T/hosts" "$FOREIGN"; says "+ $FOREIGN" changes; fi
  cp "$T/hosts" "$T/after"; says "Nothing to repair" repair; same_file "$T/hosts" "$T/after"
  h off development >/dev/null && h on development >/dev/null || fail "on/off should work after repair"
}

test_check_healthy() { healthy_start; says "No problems found" check; says "Nothing to repair" repair; }

test_repair_localhost_deleted() {
  healthy_start; sed -i '' '/^127.0.0.1	localhost$/d' "$T/hosts"
  local out; out="$(h on staging 2>&1)" && fail "on should be blocked until repaired"
  [[ "$out" == *"fix it with: hosts repair"* ]] || fail "should point to hosts repair"
  repaired_ok
}

test_repair_localhost_commented_out() {
  healthy_start; sed -i '' 's/^127.0.0.1	localhost$/#127.0.0.1	localhost/' "$T/hosts"
  repaired_ok
}

test_repair_other_standard_lines() {
  healthy_start; sed -i '' -e '/^255.255.255.255/d' -e '/^::1/d' "$T/hosts"
  says "broadcasthost\" is missing" check
  h off development >/dev/null || fail "missing ::1/broadcasthost shouldn't block on/off"
  h on development >/dev/null
  repaired_ok; contains "$T/hosts" "broadcasthost"; contains "$T/hosts" "::1"
}

test_repair_end_marker_deleted() {
  healthy_start; sed -i '' '/^# <<< hosts-set:development$/d' "$T/hosts"; echo "$FOREIGN" >> "$T/hosts"
  repaired_ok 1
}

test_repair_start_marker_deleted() {
  healthy_start; sed -i '' '/^# >>> hosts-set:local-stack$/d' "$T/hosts"; echo "$FOREIGN" >> "$T/hosts"
  repaired_ok 1
}

test_repair_file_replaced_by_installer() {
  healthy_start; printf '%s\n127.0.0.1 api.proj.example.dev\n' "$FOREIGN" > "$T/hosts"
  repaired_ok 1
  contains "$T/hosts" "# Host Database"                            # fixed section comes back in order
  check [ "$(head -1 "$T/hosts")" = "##" ]
}

test_repair_file_emptied() {
  healthy_start; : > "$T/hosts"
  says "missing or empty" check 2>&1 || true
  repaired_ok
}

test_repair_crlf() {
  healthy_start; sed -i '' 's/$/'$'\r''/' "$T/hosts"
  says "CRLF" check 2>&1 || true
  repaired_ok; ! grep -q $'\r' "$T/hosts" || fail "CRLF should be gone"
}

test_repair_append_without_final_newline() {
  healthy_start; printf '%s' "$(cat "$T/hosts")" > "$T/hosts.t"; mv "$T/hosts.t" "$T/hosts"
  says "no line break" check 2>&1 || true
  printf '%s\n' "$FOREIGN" >> "$T/hosts"                            # glued onto the last end marker
  repaired_ok 1
}

test_repair_permissions() {
  healthy_start; chmod 600 "$T/hosts"; cp "$T/hosts" "$T/before"
  says "permissions are 600" check 2>&1 || true
  echo y | h repair >/dev/null; check [ "$(stat -f %Lp "$T/hosts")" = 644 ]
  same_file "$T/hosts" "$T/before"
}

test_repair_edit_inside_block() {
  healthy_start; sed -i '' 's/^127.0.0.2 site-two.test$/10.9.9.9 site-two.test/' "$T/hosts"
  says "was changed inside" check 2>&1 || true
  repaired_ok
  contains "$T/hosts" "127.0.0.2 site-two.test"                    # set's own line back in its block
  contains "$T/hosts" "10.9.9.9 site-two.test"; says "+ 10.9.9.9 site-two.test" changes   # installer's kept, flagged
}

test_repair_duplicated_block() {
  healthy_start
  awk -v b="# >>> hosts-set:development" -v e="# <<< hosts-set:development" '$0 == b { p = 1 } p { print } $0 == e { p = 0 }' "$T/hosts" > "$T/dup"
  { echo; cat "$T/dup"; } >> "$T/hosts"
  says "appears twice" check 2>&1 || true
  repaired_ok; count "$T/hosts" "# >>> hosts-set:development" 1
}

test_repair_block_removed() {
  healthy_start
  awk -v b="# >>> hosts-set:local-stack" -v e="# <<< hosts-set:local-stack" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$T/hosts" > "$T/h"; mv "$T/h" "$T/hosts"
  says "was on, but its lines have been removed" check 2>&1 || true
  repaired_ok
}

test_repair_recovers_deleted_set_file() {
  healthy_start; rm "$T/sets/local-stack.hosts"; sed -i '' '/^# <<< hosts-set:local-stack$/d' "$T/hosts"
  echo y | h repair >/dev/null
  check [ -f "$T/sets/local-stack.hosts" ]; contains "$T/sets/local-stack.hosts" "api.example.dev"
  says "No problems found" check; set_on local-stack
}

test_repair_cancel_changes_nothing() {
  healthy_start; sed -i '' '/^127.0.0.1	localhost$/d' "$T/hosts"; cp "$T/hosts" "$T/before"
  echo n | says cancelled repair
  same_file "$T/hosts" "$T/before"
}

test_repair_respects_direct_set_file_edit() {
  healthy_start
  sed -i '' '/site-two.test/d' "$T/sets/development.hosts"        # edited by hand, not yet applied
  says "edits that aren't applied yet" check
  echo y | h repair >/dev/null
  lacks "$T/hosts" "site-two.test"; says "No changes outside your sets" changes
  says "No problems found" check
}

test_repair_after_blocked_edit() {
  healthy_start; sed -i '' '/^# <<< hosts-set:local-stack$/d' "$T/hosts"   # damaged
  local ed="$T/ed"; printf '#!/bin/sh\nsed -i "" "/site-two.test/d" "$1"\n' > "$ed"; chmod +x "$ed"
  ! EDITOR="$ed" h edit development >/dev/null 2>&1; check [ $? = 0 ]      # saved, but write blocked
  echo y | h repair >/dev/null
  lacks "$T/hosts" "site-two.test"; says "No changes outside your sets" changes
  set_on development; set_on local-stack; says "No problems found" check
}

test_crlf_file_still_lists_and_switches() {
  healthy_start; sed -i '' 's/$/'$'\r''/' "$T/hosts"
  set_on development; set_off staging
  h off development >/dev/null; set_off development; lacks "$T/hosts" "site-one.test"
  ! grep -q $'\r' "$T/hosts" || fail "on/off shouldn't leave CRLF behind"
}

test_vanished_check_uses_exact_names() {
  fresh; echo "10.0.0.1 a.test" > "$T/sets/dev.hosts"; echo "10.0.0.2 b.test" > "$T/sets/development.hosts"
  h on dev >/dev/null; h on development >/dev/null
  awk -v b="# >>> hosts-set:dev" -v e="# <<< hosts-set:dev" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$T/hosts" > "$T/h"; mv "$T/h" "$T/hosts"
  says 'set "dev" was on, but its lines have been removed' check
}

# --- run ---------------------------------------------------------------------

echo "Running hosts tests"
for t in $(declare -F | awk '{print $3}' | grep '^test_' | sed 's/^test_//'); do run "$t"; done
echo
echo "$pass passed, $fail failed"
[ $fail = 0 ]
