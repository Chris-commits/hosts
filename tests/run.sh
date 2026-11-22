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

# --- run ---------------------------------------------------------------------

echo "Running hosts tests"
for t in $(declare -F | awk '{print $3}' | grep '^test_' | sed 's/^test_//'); do run "$t"; done
echo
echo "$pass passed, $fail failed"
[ $fail = 0 ]
