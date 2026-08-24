#!/usr/bin/env bash
# Selftest for the migration-number-race machinery (issue #64) in run-workflow.sh.
#
#   bash factory/tests/migration-race-selftest.sh
#
# Exists because the path's FIRST live run misfired in a way no interactive test
# could catch: under the tick's launchd AGENT_PATH bare `node` is exit 127, and the
# original detection read that exit code as "duplicate migration detected" — so a
# branch with NO migrations at all (PR #66, run 20260820T171830) escalated to a
# human under the duplicate-number message. Every test here therefore runs with a
# BROKEN `node` on PATH (a shim that exits 127) unless it explicitly opts into the
# real one via FACTORY_TRIGGER_PROGRAM — the same resolution order the factory uses.
#
# The functions under test are extracted VERBATIM from run-workflow.sh — this file
# never re-implements them, so it cannot drift into testing a copy.
#
# T1  branch adds no migration, node broken            -> rc 0 (the PR #66 regression)
# T2  genuine collision, node broken                   -> rc 2 (machinery, NOT duplicate)
# T3  genuine collision, FACTORY_TRIGGER_PROGRAM=real  -> rc 0, renumbered + header + marker
# T4  branch-internal duplicate, real node             -> rc 1 (ambiguity, human decides)
# T5  one base file + TWO branch files on one number   -> rc 1, NOTHING renumbered
# T6  stale RENUMBERED marker from an earlier pass     -> rc 0, marker holds only this pass

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/../run-workflow.sh"
GEN="$HERE/../../scripts/gen-migrations-index.mjs"
[ -f "$RUNNER" ] || { echo "FATAL: $RUNNER not found"; exit 2; }
[ -f "$GEN" ]    || { echo "FATAL: $GEN not found"; exit 2; }

REAL_NODE="$(command -v node || true)"
[ -n "$REAL_NODE" ] || { echo "FATAL: this selftest needs a real node to prove T3; none on PATH"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The broken-PATH shim: resolvable, executable, and useless — models the tick's
# environment where resolution succeeds interactively and dies headless.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\nexit 127\n' > "$SHIM/node"; chmod +x "$SHIM/node"

# Functions under test, extracted verbatim.
FUNCS="$TMP/funcs.sh"
awk '/^factory_node\(\)/,/^}/'                 "$RUNNER"  > "$FUNCS"
awk '/^settle_index_conflicts\(\)/,/^}/'       "$RUNNER" >> "$FUNCS"
awk '/^renumber_duplicate_migrations\(\)/,/^}/' "$RUNNER" >> "$FUNCS"
[ "$(grep -c '^}' "$FUNCS")" -eq 3 ] || { echo "FATAL: could not extract the 3 functions from $RUNNER"; exit 2; }

GITC="-c user.name=selftest -c user.email=selftest@vox.invalid"

mk_repo() {   # mk_repo <dir>  — develop with 00168 committed
  local d="$1"
  mkdir -p "$d"; cd "$d"
  git init -q -b develop
  mkdir -p supabase/migrations scripts
  cp "$GEN" scripts/
  printf -- '-- 00168 | 2026-08-18 | baseline\nselect 1;\n' > supabase/migrations/00168_baseline.sql
  git add -A; git $GITC commit -qm base
}

run_case() {  # run_case <repo> <trigger_program_or_-> ; echoes rc
  local repo="$1" trig="$2"
  ( cd "$repo"
    export PATH="$SHIM:$PATH"
    if [ "$trig" = "-" ]; then unset FACTORY_TRIGGER_PROGRAM; else export FACTORY_TRIGGER_PROGRAM="$trig"; fi
    RUNDIR="$repo/.rundir"; mkdir -p "$RUNDIR"
    BASE=develop; ISSUE_NUM=0
    log() { echo "[log] $*"; }
    . "$FUNCS"
    rc=0; renumber_duplicate_migrations "$repo" || rc=$?
    echo "$rc" > "$RUNDIR/rc"
  ) >/dev/null 2>&1
  cat "$repo/.rundir/rc" 2>/dev/null || echo "crashed"
}

FAILED=0
check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: expected $2, got $3"; FAILED=1; fi
}

# T1 — no-migration branch, node broken everywhere: the PR #66 regression.
( mk_repo "$TMP/t1"
  git checkout -qb feature
  mkdir -p src; echo "test only" > src/change.txt
  git add -A; git $GITC commit -qm "no migrations here" ) >/dev/null 2>&1
check "T1 no-migration branch, broken node -> 0" 0 "$(run_case "$TMP/t1" -)"

# T2 — genuine collision (post-rebase shape: both files in the tree), node broken:
# must be rc 2 (machinery), never rc 1 (duplicate) — the conflation the live run hit.
( mk_repo "$TMP/t2"
  printf -- '-- 00169 | 2026-08-19 | first to merge\nselect 2;\n' > supabase/migrations/00169_first.sql
  git add -A; git $GITC commit -qm "develop takes 00169"
  git checkout -qb feature
  printf -- '-- 00169 | 2026-08-19 | second in flight\nselect 3;\n' > supabase/migrations/00169_second.sql
  git add -A; git $GITC commit -qm "branch also mints 00169" ) >/dev/null 2>&1
check "T2 collision, broken node -> 2 (machinery)" 2 "$(run_case "$TMP/t2" -)"

# T3 — same collision, FACTORY_TRIGGER_PROGRAM points at the real node while PATH
# stays broken: proves the absolute resolution is preferred AND the happy path works.
( mk_repo "$TMP/t3"
  printf -- '-- 00169 | 2026-08-19 | first to merge\nselect 2;\n' > supabase/migrations/00169_first.sql
  git add -A; git $GITC commit -qm "develop takes 00169"
  git checkout -qb feature
  printf -- '-- 00169 | 2026-08-19 | second in flight\nselect 3;\nselect 4;\n' > supabase/migrations/00169_second.sql
  git add -A; git $GITC commit -qm "branch also mints 00169" ) >/dev/null 2>&1
check "T3 collision, real node via FACTORY_TRIGGER_PROGRAM -> 0" 0 "$(run_case "$TMP/t3" "$REAL_NODE")"
[ -f "$TMP/t3/supabase/migrations/00170_second.sql" ]; check "T3 file renamed to 00170" 0 "$?"
head -1 "$TMP/t3/supabase/migrations/00170_second.sql" 2>/dev/null | grep -q '^-- 00170 '; check "T3 header renumbered" 0 "$?"
tail -n +2 "$TMP/t3/supabase/migrations/00170_second.sql" 2>/dev/null | cmp -s - <(printf 'select 3;\nselect 4;\n'); check "T3 body byte-identical" 0 "$?"
grep -q '00169_second.sql -> 00170_second.sql' "$TMP/t3/.rundir/RENUMBERED" 2>/dev/null; check "T3 RENUMBERED marker" 0 "$?"

# T4 — the branch itself carries two files with one number: no mechanical answer,
# rc 1, human decides. Real node, so the failure cannot be a tooling one.
( mk_repo "$TMP/t4"
  git checkout -qb feature
  printf -- '-- 00169 | 2026-08-19 | one\nselect 2;\n' > supabase/migrations/00169_one.sql
  printf -- '-- 00169 | 2026-08-19 | two\nselect 3;\n' > supabase/migrations/00169_two.sql
  git add -A; git $GITC commit -qm "branch-internal duplicate" ) >/dev/null 2>&1
check "T4 branch-internal dupe, real node -> 1 (ambiguity)" 1 "$(run_case "$TMP/t4" "$REAL_NODE")"

# T5 — one base file + TWO branch files carry the number: the pair guard must count
# BOTH sides. A branch-side count that goes unchecked renumbers whichever file the
# glob visits last and leaves the other colliding — partial rewrite, then rc 0.
( mk_repo "$TMP/t5"
  printf -- '-- 00169 | 2026-08-19 | first to merge\nselect 2;\n' > supabase/migrations/00169_first.sql
  git add -A; git $GITC commit -qm "develop takes 00169"
  git checkout -qb feature
  printf -- '-- 00169 | 2026-08-19 | branch a\nselect 3;\n' > supabase/migrations/00169_branch_a.sql
  printf -- '-- 00169 | 2026-08-19 | branch b\nselect 4;\n' > supabase/migrations/00169_branch_b.sql
  git add -A; git $GITC commit -qm "branch mints 00169 twice" ) >/dev/null 2>&1
check "T5 one base + two branch files, real node -> 1 (ambiguity)" 1 "$(run_case "$TMP/t5" "$REAL_NODE")"
[ -f "$TMP/t5/supabase/migrations/00169_branch_a.sql" ] && [ -f "$TMP/t5/supabase/migrations/00169_branch_b.sql" ] \
  && [ ! -f "$TMP/t5/supabase/migrations/00170_branch_a.sql" ] && [ ! -f "$TMP/t5/supabase/migrations/00170_branch_b.sql" ]
check "T5 nothing renumbered before the refusal" 0 "$?"

# T6 — a RENUMBERED marker left by an earlier pass of the same run: the marker feeds
# the commit message, so it must hold ONLY this pass's renames, never stale ones.
( mk_repo "$TMP/t6"
  printf -- '-- 00169 | 2026-08-19 | first to merge\nselect 2;\n' > supabase/migrations/00169_first.sql
  git add -A; git $GITC commit -qm "develop takes 00169"
  git checkout -qb feature
  printf -- '-- 00169 | 2026-08-19 | second in flight\nselect 3;\n' > supabase/migrations/00169_second.sql
  git add -A; git $GITC commit -qm "branch also mints 00169" ) >/dev/null 2>&1
mkdir -p "$TMP/t6/.rundir"
echo "00050_stale.sql -> 00051_stale.sql" > "$TMP/t6/.rundir/RENUMBERED"
check "T6 collision with stale marker, real node -> 0" 0 "$(run_case "$TMP/t6" "$REAL_NODE")"
grep -q '00169_second.sql -> 00170_second.sql' "$TMP/t6/.rundir/RENUMBERED" 2>/dev/null \
  && ! grep -q 'stale' "$TMP/t6/.rundir/RENUMBERED"
check "T6 marker holds only this pass's rename" 0 "$?"
git -C "$TMP/t6" log -1 --format=%B 2>/dev/null | grep -q 'stale'; [ "$?" -ne 0 ]
check "T6 stale rename absent from the commit message" 0 "$?"

[ "$FAILED" -eq 0 ] && echo "ALL PASS" || echo "SELFTEST FAILED"
exit "$FAILED"
