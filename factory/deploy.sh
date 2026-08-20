#!/usr/bin/env bash
# Component 3 — deployment closure, VOX shape (dark-factory program, Phase E).
# THE LOOP IS NOT CLOSED UNTIL A STRANGER CAN SEE THE CHANGE.
#
#   bash factory/deploy.sh              # deploy every Edge Function that changed on
#                                       # origin/develop since the last deploy
#   bash factory/deploy.sh --dry-run    # print what it would do; touch nothing
#   bash factory/deploy.sh --rollback   # redeploy the previous pointer's code for the
#                                       # functions the last deploy touched
#   bash factory/deploy.sh --seed <sha> # one-time baseline (refuses if already seeded)
#
# WHAT THIS DEPLOYS AND WHAT IT NEVER TOUCHES. The D1 territory's deployable surface is
# Supabase Edge Functions, shipped with the supabase CLI to the hosted project. The
# production DATABASE is not deployable by anyone but a human, permanently (program
# dossier 03 §4.4; FACTORY_RULES.md §2.3) — and this script REFUSES to deploy any range
# that contains a migration file, because an EF that needs schema the human has not
# applied yet must wait for the human, not race them.
#
# The template's shape (build snapshot → health check → pointer swap) survives with one
# honest difference: Supabase platform deploys have no staging slot, so the swap happens
# AT deploy and the health check runs AFTER it. The compensations: (1) every deployed
# range already passed the full local gate — functions served, E2E driven over http —
# before it was allowed to merge; (2) verification here is positive (version bump +
# ACTIVE + import map present, then a boot probe per function); (3) a failed check
# AUTO-ROLLS-BACK everything this run deployed, then escalates. Rollback is one command,
# decided now rather than during the incident.
#
# NOT push-triggered, and that is the trap that silently kills factories: GitHub does not
# trigger workflows on commits made with the default GITHUB_TOKEN. This repo has NO
# GitHub-hosted deploy at all — this script IS the deploy, it polls origin/develop when
# invoked, and a poll cannot be silently skipped. (The factory's pushes authenticate as
# a real user's OAuth token besides, which is why CI fires on its merges.)
#
# It NO-OPS when nothing changed. An unattended deploy loop runs far more often than it
# deploys. Prefer the mechanism that fails loudly.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# shellcheck source=factory/config.sh
. "$ROOT/factory/config.sh"

REF="${FACTORY_DEPLOY_PROJECT_REF:?FACTORY_DEPLOY_PROJECT_REF is not set in factory/config.sh}"
EF_BASE_URL="${FACTORY_EF_BASE_URL:-https://$REF.supabase.co/functions/v1}"
EXCLUDE="${FACTORY_DEPLOY_EXCLUDE:-}"
BASE_BRANCH="${FACTORY_BASE_BRANCH:-develop}"

STATE_DIR=".factory/deploy"
POINTER="$STATE_DIR/CURRENT"     # the develop sha the prod EF fleet was last brought level with
HISTORY="$STATE_DIR/HISTORY"     # append-only: <utc> <action> <from> <to> <fn,fn,...>
LOGS="$STATE_DIR/logs"
mkdir -p "$STATE_DIR" "$LOGS"

RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG="$LOGS/$RUN_TS.log"

MODE="deploy"
SEED_SHA=""
case "${1:-}" in
  "")          MODE="deploy" ;;
  --dry-run)   MODE="dry-run" ;;
  --rollback)  MODE="rollback" ;;
  --seed)      MODE="seed"; SEED_SHA="${2:?--seed needs a sha}" ;;
  *) echo "DEPLOY_REFUSED: unknown argument '$1' (know: --dry-run, --rollback, --seed <sha>)"; exit 1 ;;
esac

# --- the stop button, honored before anything else ----------------------------
if [ -f "${FACTORY_STOP_FILE:-.factory/STOP}" ] && [ "$MODE" != "dry-run" ]; then
  echo "DEPLOY_REFUSED: ${FACTORY_STOP_FILE:-.factory/STOP} exists - the factory is stopped"
  exit 2
fi

# --- one deploy at a time -----------------------------------------------------
LOCK="$STATE_DIR/.lock"
if [ "$MODE" != "dry-run" ]; then
  if ! mkdir "$LOCK" 2>/dev/null; then
    echo "DEPLOY_REFUSED: another deploy holds $LOCK (remove it only if you are sure it is dead)"
    exit 1
  fi
  trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT INT TERM
fi

# --- seeding ------------------------------------------------------------------
if [ "$MODE" = "seed" ]; then
  if [ -f "$POINTER" ]; then
    echo "DEPLOY_REFUSED: already seeded ($(cat "$POINTER")). Re-seeding rewrites what"
    echo "  'level with prod' means; if you really mean it, delete $POINTER by hand first."
    exit 1
  fi
  git rev-parse --verify --quiet "$SEED_SHA^{commit}" >/dev/null \
    || { echo "DEPLOY_REFUSED: '$SEED_SHA' is not a commit this checkout knows"; exit 1; }
  FULL_SEED="$(git rev-parse "$SEED_SHA")"
  echo "$FULL_SEED" > "$POINTER"
  echo "$(date -u +%FT%TZ) seed - $FULL_SEED -" >> "$HISTORY"
  echo "DEPLOY_SEEDED sha=$FULL_SEED"
  echo "  The pointer's contract starts NOW: divergence older than this sha is not this"
  echo "  script's to see. Reconcile anything you know is behind before trusting it."
  exit 0
fi

[ -f "$POINTER" ] || {
  echo "DEPLOY_REFUSED: no baseline. Seed one first:"
  echo "  bash factory/deploy.sh --seed <sha the prod EF fleet is currently level with>"
  exit 1
}
BASE_SHA="$(cat "$POINTER")"

# --- helpers ------------------------------------------------------------------
# The management API's own view of the fleet: name, version, status, bundle hash,
# import map path. This is the positive evidence source — never "the CLI exited 0".
list_fleet() {  # list_fleet <outfile>
  supabase functions list --project-ref "$REF" --output json > "$1" 2>>"$RUN_LOG" \
    || { echo "DEPLOY_REFUSED: 'supabase functions list' failed - cannot verify anything without it"; return 1; }
  python3 - "$1" <<'PY' || return 1
import json, sys
fleet = json.load(open(sys.argv[1]))
assert isinstance(fleet, list) and fleet, "functions list returned no functions"
PY
}

fleet_get() {  # fleet_get <file> <fn> <field>  -> value or empty
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
fleet = {f["name"]: f for f in json.load(open(sys.argv[1]))}
f = fleet.get(sys.argv[2], {})
v = f.get(sys.argv[3], "")
print(v if v is not None else "")
PY
}

# Boot probe. OPTIONS goes through the gateway without a JWT (a CORS preflight cannot
# carry auth), so the DEPLOYED BUNDLE itself must boot and answer. Fail codes are the
# infrastructure/boot classes; a function's own 4xx is a booted function talking.
probe_fn() {  # probe_fn <fn> -> echoes http code; rc 0 booted / 1 not
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -X OPTIONS --max-time 30 \
          "$EF_BASE_URL/$1" 2>>"$RUN_LOG" || echo 000)"
  echo "$code"
  case "$code" in
    000|502|503|504|546) return 1 ;;
    *) return 0 ;;
  esac
}

# Deploy one function from a worktree. The import-map flag is deliberately NOT passed:
# on CLI 2.109.1 it is ignored with a warning, and auto-discovery of
# supabase/functions/deno.json is verified POSITIVELY after the fact (import_map_path in
# the fleet listing) instead of guessed at before. If discovery ever breaks again the
# way it did on 2026-08-04, the deploy fails loudly at bundling — which is the good
# direction to fail.
deploy_fn() {  # deploy_fn <worktree> <fn>
  # Per-function output is captured to its own part-file (then appended to RUN_LOG)
  # because the CLI's "No change found in Function: X" line is a health signal the
  # verify stage needs: an unchanged bundle is skipped by the CLI — no upload, no
  # version bump — and that is SUCCESS (the function is already at target content),
  # not a deploy that "did not take". First live widened-set verify (2026-08-17)
  # read exactly that as failure and rolled back 37 healthy functions.
  local out="$RUN_LOG.$2.part" rc=0
  ( cd "$1" && supabase functions deploy "$2" --project-ref "$REF" ) >"$out" 2>&1 || rc=$?
  cat "$out" >>"$RUN_LOG"
  return $rc
}

fn_had_no_change() {  # fn_had_no_change <fn>
  if grep -q "No change found in Function: $1" "$RUN_LOG.$1.part" 2>/dev/null; then
    return 0
  fi
  return 1
}

make_tree() {  # make_tree <sha> -> echoes worktree path
  local wt=".worktrees/deploy-$RUN_TS-${2:-src}"
  git worktree add --detach --quiet "$wt" "$1" >>"$RUN_LOG" 2>&1 || return 1
  echo "$wt"
}

reap_trees() {
  local wt
  for wt in .worktrees/deploy-"$RUN_TS"-*; do
    [ -d "$wt" ] || continue
    git worktree remove --force "$wt" >>"$RUN_LOG" 2>&1 || true
  done
}

is_excluded() {  # is_excluded <fn>
  local e
  for e in $EXCLUDE; do [ "$e" = "$1" ] && return 0; done
  return 1
}

# Redeploy <fn...> from <sha>. Used by --rollback and by the auto-rollback that runs
# when a verification or boot probe fails mid-deploy. Best-effort ON PURPOSE: when this
# runs, prod is already wrong, and stopping halfway through putting it back is worse
# than pressing on and reporting what stuck.
redeploy_from() {  # redeploy_from <sha> <fn...>
  local sha="$1"; shift
  local wt fn failed=""
  wt="$(make_tree "$sha" back)" || { echo "ROLLBACK_FAILED: could not build a worktree at $sha"; return 1; }
  for fn in "$@"; do
    if deploy_fn "$wt" "$fn"; then
      echo "ROLLBACK_FN_OK name=$fn"
    else
      failed="$failed $fn"
      echo "ROLLBACK_FN_FAILED name=$fn"
    fi
  done
  [ -z "$failed" ] || { echo "ROLLBACK_INCOMPLETE:$failed - these still run the NEW code"; return 1; }
  return 0
}

# --- rollback mode ------------------------------------------------------------
if [ "$MODE" = "rollback" ]; then
  LAST="$(grep ' deploy ' "$HISTORY" 2>/dev/null | tail -1 || true)"
  [ -n "$LAST" ] || { echo "ROLLBACK_FAILED: no deploy in $HISTORY to roll back"; exit 1; }
  FROM_SHA="$(echo "$LAST" | awk '{print $3}')"   # the state BEFORE the last deploy
  UNDONE_SHA="$(echo "$LAST" | awk '{print $4}')" # the deploy being undone
  FNS="$(echo "$LAST" | awk '{print $5}' | tr ',' ' ')"
  echo "ROLLBACK_START to=$FROM_SHA fns=$(echo "$FNS" | wc -w | tr -d ' ')"
  if redeploy_from "$FROM_SHA" $FNS; then
    FAILED_PROBE=""
    for fn in $FNS; do
      CODE="$(probe_fn "$fn")" || FAILED_PROBE="$FAILED_PROBE $fn($CODE)"
      echo "BOOT_PROBE name=$fn code=$CODE"
    done
    echo "$FROM_SHA" > "$POINTER"
    echo "$(date -u +%FT%TZ) rollback $UNDONE_SHA $FROM_SHA $(echo "$FNS" | tr ' ' ',')" >> "$HISTORY"
    reap_trees
    if [ -n "$FAILED_PROBE" ]; then
      echo "ROLLED_BACK to=$FROM_SHA BUT boot probes failed:$FAILED_PROBE"
      factory_notify "deploy" "rollback redeployed $FROM_SHA but these functions do not answer:$FAILED_PROBE"
      exit 1
    fi
    echo "ROLLED_BACK to=$FROM_SHA"
    exit 0
  else
    factory_notify "deploy" "rollback to $FROM_SHA is INCOMPLETE - see $RUN_LOG"
    reap_trees
    exit 1
  fi
fi

# --- what changed -------------------------------------------------------------
git fetch --quiet origin "$BASE_BRANCH" \
  || { echo "DEPLOY_REFUSED: cannot fetch origin/$BASE_BRANCH - not deploying against a stale view"; exit 1; }
TARGET_SHA="$(git rev-parse "origin/$BASE_BRANCH")"

if [ "$BASE_SHA" = "$TARGET_SHA" ]; then
  echo "DEPLOY_NOOP sha=$TARGET_SHA already level"
  exit 0
fi

git merge-base --is-ancestor "$BASE_SHA" "$TARGET_SHA" \
  || { echo "DEPLOY_REFUSED: pointer $BASE_SHA is not an ancestor of origin/$BASE_BRANCH -"
       echo "  history moved in a way this script cannot reason about. A human decides."
       factory_notify "deploy" "deploy pointer $BASE_SHA is not an ancestor of origin/$BASE_BRANCH"
       exit 1; }

RANGE_FILES="$(git diff --name-only "$BASE_SHA..$TARGET_SHA")"

# DB FIRST, CODE SECOND ("Last Step", Rick 2026-08-17). A range carrying new
# migrations applies them to prod through factory/db-apply.sh: static allowlist →
# independent migration judge → human floor (see FACTORY_RULES §2.4a). One failure
# anywhere = stop: db-apply exits non-zero, the pointer stays put, no Edge Function
# deploys. DDL is never auto-rolled-back (Portal-1.5: reversing schema is judgment).
MIGRATIONS_IN_RANGE="$(echo "$RANGE_FILES" | grep -c '^supabase/migrations/' || true)"
if [ "$MIGRATIONS_IN_RANGE" -gt 0 ]; then
  if [ "$MODE" = "dry-run" ]; then
    bash factory/db-apply.sh "$BASE_SHA" "$TARGET_SHA" --dry-run \
      || { echo "DRY_RUN: the migration range would PARK (see the policy verdicts above)"; exit 0; }
  else
    bash factory/db-apply.sh "$BASE_SHA" "$TARGET_SHA" || {
      echo "DEPLOY_HALTED: prod DB apply did not complete - db-apply.sh escalated with"
      echo "  the evidence; the pointer stays at $BASE_SHA and no Edge Function deploys."
      exit 1
    }
    echo "DB_FIRST_OK: the range's migrations are applied and verified - EF deploy proceeds"
  fi
fi

# GUARD: supabase/config.toml carries verify_jwt per function — the auth surface. A
# range that changes it does not deploy unattended.
if echo "$RANGE_FILES" | grep -q '^supabase/config.toml$'; then
  echo "DEPLOY_REFUSED: supabase/config.toml changed in range - per-function verify_jwt"
  echo "  lives there, and auth surface changes deploy under human eyes only."
  [ "$MODE" = "dry-run" ] || factory_notify "deploy" "deploy range changes supabase/config.toml (auth surface): $BASE_SHA..$TARGET_SHA"
  exit 1
fi

EF_FILES="$(echo "$RANGE_FILES" | grep '^supabase/functions/' || true)"
if [ -z "$EF_FILES" ]; then
  # Nothing deployable moved. Advance the pointer so docs/src-only merges do not pile
  # up as forever-"pending" — the pointer means "processed up to here", and processed
  # this range is exactly what just happened.
  if [ "$MODE" = "dry-run" ]; then
    echo "DRY_RUN: no Edge Function paths in $BASE_SHA..$TARGET_SHA - a real run would advance the pointer"
    exit 0
  fi
  echo "$TARGET_SHA" > "$POINTER"
  echo "$(date -u +%FT%TZ) advance $BASE_SHA $TARGET_SHA -" >> "$HISTORY"
  echo "DEPLOY_NOOP_EF advanced=$TARGET_SHA (no Edge Function changes in range)"
  exit 0
fi

# The roster of what is actually deployable is the REMOTE's, not the tree's: a function
# that has never been deployed gets its FIRST deploy from a human (new surface, new
# secrets, new config — a judgement, not a refresh).
PRE_LIST="$STATE_DIR/.pre-$RUN_TS.json"
list_fleet "$PRE_LIST" || exit 1
REMOTE_FNS="$(python3 -c "
import json,sys
print(' '.join(sorted(f['name'] for f in json.load(open('$PRE_LIST')) if f.get('status')=='ACTIVE')))
")"

# Shared code or the import map moved -> every deployed function's next bundle changes.
if echo "$EF_FILES" | grep -Eq '^supabase/functions/(_shared/|deno\.json)'; then
  CANDIDATES="$REMOTE_FNS"
  echo "DEPLOY_SET_WIDENED reason=_shared-or-deno.json-changed"
else
  CANDIDATES="$(echo "$EF_FILES" | sed -n 's|^supabase/functions/\(fn-[a-z0-9-]*\)/.*|\1|p' | sort -u | tr '\n' ' ')"
fi

SET="" ; SKIPPED_EXCLUDED="" ; SKIPPED_UNDEPLOYED="" ; SKIPPED_DELETED=""
for fn in $CANDIDATES; do
  if is_excluded "$fn"; then SKIPPED_EXCLUDED="$SKIPPED_EXCLUDED $fn"; continue; fi
  # The widened set comes FROM the remote roster, so a function deleted from the repo
  # but still ACTIVE on prod entered the plan with no source and died at bundle --
  # torching the run and rolling back 35 healthy deploys (fn-weather-enrich, first
  # live dial-3 deploy). No entrypoint at the target commit means there is nothing to
  # deploy: skip it loudly. Removing the remote function itself is a human act.
  if ! git cat-file -e "$TARGET_SHA:supabase/functions/$fn/index.ts" 2>/dev/null; then
    SKIPPED_DELETED="$SKIPPED_DELETED $fn"; continue
  fi
  case " $REMOTE_FNS " in
    *" $fn "*) SET="$SET $fn" ;;
    *) SKIPPED_UNDEPLOYED="$SKIPPED_UNDEPLOYED $fn" ;;
  esac
done
SET="${SET# }"

echo "DEPLOY_PLAN base=$BASE_SHA target=$TARGET_SHA fns=$(echo "$SET" | wc -w | tr -d ' ')"
[ -z "$SET" ] || echo "  deploying:$(echo " $SET" | tr '\n' ' ')"
[ -z "$SKIPPED_EXCLUDED" ]   || echo "  HUMAN-OWNED, not deployed:$SKIPPED_EXCLUDED (FACTORY_DEPLOY_EXCLUDE)"
[ -z "$SKIPPED_UNDEPLOYED" ] || echo "  NEVER DEPLOYED, not deployed:$SKIPPED_UNDEPLOYED (first deploys are human)"
[ -z "$SKIPPED_DELETED" ]    || echo "  IN PROD BUT DELETED IN REPO, not deployed:$SKIPPED_DELETED (deleting a prod function is a human act)"

if [ "$MODE" = "dry-run" ]; then
  echo "DRY_RUN: stopping here - nothing was deployed, no state moved"
  rm -f "$PRE_LIST"
  exit 0
fi

# Anything skipped still leaves this run with a clean conscience ONLY if a human heard
# about it. The pointer advances below either way — the record of the skip is the
# notification plus HISTORY, not a wedged pointer.
[ -z "$SKIPPED_EXCLUDED$SKIPPED_UNDEPLOYED$SKIPPED_DELETED" ] \
  || factory_notify "deploy" "range $BASE_SHA..$TARGET_SHA touched functions this script will not deploy:${SKIPPED_EXCLUDED}${SKIPPED_UNDEPLOYED}${SKIPPED_DELETED} - they are yours"

if [ -z "$SET" ]; then
  echo "$TARGET_SHA" > "$POINTER"
  echo "$(date -u +%FT%TZ) advance $BASE_SHA $TARGET_SHA skipped:${SKIPPED_EXCLUDED}${SKIPPED_UNDEPLOYED}${SKIPPED_DELETED}" >> "$HISTORY"
  echo "DEPLOY_NOOP_EF advanced=$TARGET_SHA (every touched function is human-owned)"
  rm -f "$PRE_LIST"
  exit 0
fi

# --- deploy, fail-fast, auto-rollback ----------------------------------------
echo "DEPLOY_START sha=$TARGET_SHA"
WT="$(make_tree "$TARGET_SHA" fwd)" \
  || { echo "DEPLOY_REFUSED: could not build a worktree at $TARGET_SHA"; exit 1; }

DEPLOYED=""
abort_and_rollback() {  # abort_and_rollback <why>
  echo "DEPLOY_FAILED: $1"
  if [ -n "$DEPLOYED" ]; then
    echo "AUTO_ROLLBACK of:$DEPLOYED"
    redeploy_from "$BASE_SHA" $DEPLOYED || true
  fi
  factory_notify "deploy" "deploy of $TARGET_SHA FAILED ($1); rolled back:$DEPLOYED - see $RUN_LOG"
  reap_trees
  exit 1
}

NO_CHANGE=""
for fn in $SET; do
  deploy_fn "$WT" "$fn" || abort_and_rollback "supabase functions deploy $fn failed (bundling or upload) - log: $RUN_LOG"
  if fn_had_no_change "$fn"; then
    # Already at target content: nothing was uploaded, so there is nothing to roll
    # back and no version bump to assert. The boot probe below still covers it.
    NO_CHANGE="$NO_CHANGE $fn"
    echo "DEPLOY_FN_OK name=$fn (no change - already at target content)"
  else
    DEPLOYED="$DEPLOYED $fn"
    echo "DEPLOY_FN_OK name=$fn"
  fi
done

# --- verify: positive evidence, never the exit code ---------------------------
POST_LIST="$STATE_DIR/.post-$RUN_TS.json"
list_fleet "$POST_LIST" || abort_and_rollback "could not list the fleet after deploying"

# Management-API assertions apply only to functions that actually uploaded: for a
# NO_CHANGE function the listing describes the PRIOR deploy (its version rightly did
# not move, and a pre-Phase-E entry may predate import_map_path entirely). Its live
# health is proven by the boot probe, which covers the full set.
[ -z "$NO_CHANGE" ] || echo "DEPLOY_FN_NOCHANGE:$NO_CHANGE (already at target content; boot probes still run)"
VERIFIED=0
for fn in $DEPLOYED; do
  V_PRE="$(fleet_get "$PRE_LIST"  "$fn" version)"
  V_POST="$(fleet_get "$POST_LIST" "$fn" version)"
  STATUS="$(fleet_get "$POST_LIST" "$fn" status)"
  IMAP="$(fleet_get "$POST_LIST" "$fn" import_map_path)"
  [ -n "$V_POST" ] && [ -n "$V_PRE" ] && [ "$V_POST" -gt "$V_PRE" ] 2>/dev/null \
    || abort_and_rollback "$fn version did not advance (pre=$V_PRE post=$V_POST) - the deploy did not take"
  [ "$STATUS" = "ACTIVE" ] \
    || abort_and_rollback "$fn status is '$STATUS' after deploy, not ACTIVE"
  case "$IMAP" in
    *deno.json) : ;;
    *) abort_and_rollback "$fn deployed WITHOUT supabase/functions/deno.json as its import map (got '$IMAP') - the 2026-08-04 CLI discovery failure shape" ;;
  esac
  echo "DEPLOY_FN_VERIFIED name=$fn version=$V_PRE->$V_POST"
  VERIFIED=$((VERIFIED + 1))
done

# --- boot probes: the bundle must answer, not merely exist --------------------
PROBED=0
for fn in $SET; do
  CODE="$(probe_fn "$fn")" || abort_and_rollback "$fn does not answer (OPTIONS -> $CODE) - boot failure class"
  echo "BOOT_OK name=$fn code=$CODE"
  PROBED=$((PROBED + 1))
done

# --- optional deep canary (FACTORY_HEALTH_CMD), markers asserted --------------
if [ -n "${FACTORY_HEALTH_CMD:-}" ]; then
  HEALTH_LOG="$LOGS/$RUN_TS-canary.log"
  eval "$FACTORY_HEALTH_CMD" > "$HEALTH_LOG" 2>&1 \
    || abort_and_rollback "deep canary FACTORY_HEALTH_CMD failed - $HEALTH_LOG"
  for MARKER in ${FACTORY_HEALTH_MARKERS:-}; do
    grep -qE "$MARKER" "$HEALTH_LOG" \
      || abort_and_rollback "deep canary ran but '$MARKER' never appeared - $HEALTH_LOG"
  done
  echo "CANARY_OK markers=$(echo "${FACTORY_HEALTH_MARKERS:-}" | wc -w | tr -d ' ')"
fi

# --- bookkeeping (the fleet is already live; nothing below may claim otherwise)
echo "$TARGET_SHA" > "$POINTER"
echo "$(date -u +%FT%TZ) deploy $BASE_SHA $TARGET_SHA $(echo "$SET" | tr ' ' ',')" >> "$HISTORY"
rm -f "$PRE_LIST" "$POST_LIST"
reap_trees

echo "DEPLOY_VERIFIED fns=$VERIFIED probed=$PROBED"
echo "DEPLOYED sha=$TARGET_SHA"
echo "LIVE: $POINTER -> $TARGET_SHA"
