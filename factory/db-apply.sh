#!/usr/bin/env bash
# Prod DB apply — the factory's last human step, automated (dark-factory, "Last Step").
# THE DB MOVES FIRST, THE CODE SECOND, AND NOBODY GUESSES.
#
#   bash factory/db-apply.sh <base_sha> <target_sha>            apply the range's new
#                                                               migrations to PROD
#   bash factory/db-apply.sh <base_sha> <target_sha> --dry-run  plan + policy verdicts only
#   bash factory/db-apply.sh --verify-endpoint                  prove token + API scope
#                                                               (read-only; run at install)
#
# WHAT THIS IS. deploy.sh refuses migration-carrying ranges because an Edge Function
# must never race its own schema. This script is the missing first half of that
# sequencing: it applies the range's NEW migration files to the production database —
# through the SAME Management API endpoint MCP apply_migration uses
# (POST /v1/projects/{ref}/database/migrations), so the remote history row it records
# (timestamp version + our readable 00NNN name) is identical BY CONSTRUCTION to how
# every migration since ~00095 was recorded. Conformance with the past is the spec.
#
# THREE RUNGS OF REVIEW (Rick's 2026-08-17 "all migrations move through" directive):
#   1. factory/db_apply_policy.py — the static allowlist. Additive, non-privilege DDL
#      applies with no further review.
#   2. THE MIGRATION JUDGE (factory/db-apply-prompts/judge.md) — an independent
#      premium-model review for everything the policy escalated: backfills, grants,
#      policies, recreatable drops, hot-table locks, DO blocks. Park-by-default; a
#      missing/malformed verdict is a park; every file it clears must carry its own
#      read-only verification SQL. Its authority is one-way: it can park a range, it
#      can never skip verification or move the pointer.
#   3. THE HUMAN FLOOR — statements that destroy stored data (TRUNCATE, DROP
#      TABLE/SCHEMA/COLUMN, DELETE) or touch the money/identity/secret schemas
#      (auth, marketing, vault, the migration ledger). The judge never sees these;
#      they park for Rick, always. That is MISSION constitution, not caution.
#
# VERIFICATION IS POSITIVE AND NON-NEGOTIABLE (deploy.sh doctrine). Every apply is
# from the FILE AT THE MERGED SHA (git show — a paraphrase cannot enter the channel),
# then: (1) the remote history row exists under our name; (2) every object-existence
# probe the policy derived — plus every verify_sql the judge demanded — returns true;
# (3) replaced functions get their pre/post definition md5 recorded in the evidence
# file. A failed apply or probe ESCALATES AND STOPS — DDL is never auto-rolled-back
# (reversing schema is a judgment call, Portal-1.5's lesson), and deploy.sh's pointer
# never advances past an unverified apply because deploy.sh only proceeds on exit 0.
#
# LIVE GUARD the static policy cannot see: before replacing a function that already
# exists in prod, ask prod whether any RLS policy references it or whether it is
# currently SECURITY DEFINER — if so, that file goes to the judge with the fact
# attached (the 00160 storage-predicate class).

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# shellcheck source=factory/config.sh
. "$ROOT/factory/config.sh"

REF="${FACTORY_DEPLOY_PROJECT_REF:?FACTORY_DEPLOY_PROJECT_REF is not set in factory/config.sh}"
API="https://api.supabase.com/v1/projects/$REF"
MIG_DIR="supabase/migrations"
POLICY="factory/db_apply_policy.py"
# Self-rendered prompt (evolve-prompts precedent): this script substitutes the
# placeholders itself, so the prompt lives OUTSIDE factory/prompts/ — the auditor
# rightly asserts the runner substitutes everything in there.
JUDGE_PROMPT="factory/db-apply-prompts/judge.md"
JUDGE_MODEL="${FACTORY_DB_JUDGE_MODEL:-${FACTORY_MODEL_PREMIUM:-opus}}"
JUDGE_BUDGET="${FACTORY_DB_JUDGE_BUDGET:-4}"

STATE_DIR=".factory/deploy"
DB_HISTORY="$STATE_DIR/DB_HISTORY"   # append-only: <utc> <action> <file> <detail>
EVIDENCE_DIR="$STATE_DIR/db-apply"
LOGS="$STATE_DIR/logs"
mkdir -p "$STATE_DIR" "$EVIDENCE_DIR" "$LOGS"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_LOG="$LOGS/db-apply-$RUN_TS.log"

log() { echo "$*" | tee -a "$RUN_LOG"; }

# ONE cleanup + ONE error trap, set once. Two `trap ... EXIT` calls overwrite each
# other silently (Phase D lap-1's cost-trap-vs-lock-trap bug class) — every later
# acquisition just assigns the variable these read. The ERR trap is the loud death:
# under set -e an unguarded failure would otherwise exit with no message, no
# notification, and a pointer nobody can trust.
LOCK=""; HDR_FILE=""; WORK=""
cleanup() {
  [ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null || true
  [ -n "$HDR_FILE" ] && rm -f "$HDR_FILE" 2>/dev/null || true
}
on_err() {
  log "DB_APPLY_DIED: unguarded failure at line $1 - nothing below it ran; the deploy pointer has not moved"
  [ "${MODE:-}" = "dry-run" ] || factory_notify "db-apply" "db-apply.sh died unexpectedly at line $1 (range ${BASE_SHA:-?}..${TARGET_SHA:-?}) - see $RUN_LOG"
}
trap 'on_err $LINENO' ERR
trap cleanup EXIT INT TERM

# --- token: env override, else the factory's own keychain entry. The CLI's own
# "Supabase CLI" keychain credential is obfuscated (proven 401 as a raw bearer,
# 2026-08-17), so the factory carries a dedicated personal access token under the
# service name below — same keychain precedent as the Slack webhook. One-time setup:
#   security add-generic-password -U -s dark-factory-db-token -a factory -w <sbp_...>
# The token NEVER appears in output, logs, or `ps`.
db_token() {
  if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then printf '%s' "$SUPABASE_ACCESS_TOKEN"; return 0; fi
  security find-generic-password -s "dark-factory-db-token" -w 2>/dev/null | tr -d '\n'
}

# --- API helpers. Responses land in files; only status codes and parsed fields are
# ever printed. curl reads the Authorization header from a private tempfile
# (-H @file) so the token is not visible in `ps`. Cleanup rides the single EXIT trap.
api_setup() {
  local tok; tok="$(db_token)"
  if [ -z "$tok" ]; then
    log "DB_APPLY_REFUSED: no Supabase access token. Set one up once:"
    log "  create a personal access token at supabase.com/dashboard/account/tokens, then"
    log "  security add-generic-password -U -s dark-factory-db-token -a factory -w <the token>"
    return 1
  fi
  HDR_FILE="$(mktemp "${TMPDIR:-/tmp}/dbapply-hdr.XXXXXX")"
  chmod 600 "$HDR_FILE"
  printf 'Authorization: Bearer %s\n' "$tok" > "$HDR_FILE"
}

api_call() {  # api_call <method> <path> <body_file|-> <out_file>  -> echoes http code
  local method="$1" path="$2" body="$3" out="$4" code
  if [ "$body" = "-" ]; then
    code="$(curl -sS -o "$out" -w '%{http_code}' --max-time 120 -X "$method" \
            -H @"$HDR_FILE" "$API$path" 2>>"$RUN_LOG" || echo 000)"
  else
    code="$(curl -sS -o "$out" -w '%{http_code}' --max-time 300 -X "$method" \
            -H @"$HDR_FILE" -H 'Content-Type: application/json' \
            --data-binary @"$body" "$API$path" 2>>"$RUN_LOG" || echo 000)"
  fi
  echo "$code"
}

# Run read-only SQL against prod via the query endpoint; result body lands in a file.
api_sql() {  # api_sql <sql> <out_file> -> rc 0 on HTTP 2xx
  local body out code
  body="$(mktemp "${TMPDIR:-/tmp}/dbapply-q.XXXXXX")"
  python3 -c 'import json,sys; print(json.dumps({"query": sys.argv[1]}))' "$1" > "$body"
  code="$(api_call POST /database/query "$body" "$2")"
  rm -f "$body"
  case "$code" in 2??) return 0 ;; *) log "DB_SQL_HTTP code=$code body=$(head -c 300 "$2")"; return 1 ;; esac
}

# --- modes -------------------------------------------------------------------
if [ "${1:-}" = "--verify-endpoint" ]; then
  api_setup || exit 1
  OUT="$(mktemp "${TMPDIR:-/tmp}/dbapply-v.XXXXXX")"
  CODE="$(api_call GET /database/migrations - "$OUT")"
  echo "ENDPOINT_MIGRATIONS_LIST http=$CODE rows=$(python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1]))))
except Exception: print("unparseable")' "$OUT")"
  if api_sql "select 1 as ok" "$OUT"; then
    echo "ENDPOINT_QUERY_OK $(head -c 120 "$OUT")"
  else
    echo "ENDPOINT_QUERY_FAILED"; rm -f "$OUT"; exit 1
  fi
  rm -f "$OUT"
  case "$CODE" in 2??) echo "DB_ENDPOINT_VERIFIED"; exit 0 ;; *) echo "DB_ENDPOINT_FAILED"; exit 1 ;; esac
fi

BASE_SHA="${1:?usage: db-apply.sh <base_sha> <target_sha> [--dry-run] | --verify-endpoint}"
TARGET_SHA="${2:?usage: db-apply.sh <base_sha> <target_sha> [--dry-run]}"
MODE="apply"; [ "${3:-}" = "--dry-run" ] && MODE="dry-run"

# --- the stop button, honored before anything else ---------------------------
if [ -f "${FACTORY_STOP_FILE:-.factory/STOP}" ] && [ "$MODE" != "dry-run" ]; then
  log "DB_APPLY_REFUSED: ${FACTORY_STOP_FILE:-.factory/STOP} exists - the factory is stopped"
  exit 2
fi

# --- one apply at a time (release rides the single EXIT trap) -----------------
if [ "$MODE" != "dry-run" ]; then
  if ! mkdir "$STATE_DIR/.db-lock" 2>/dev/null; then
    log "DB_APPLY_REFUSED: another apply holds $STATE_DIR/.db-lock (remove it only if you are sure it is dead)"
    exit 1
  fi
  LOCK="$STATE_DIR/.db-lock"
fi

# --- what the range adds. The pre-merge gate (migration_lint) already proved the
# range is append-only and conformant; anything else appearing here means the gate
# was bypassed — refuse, never adapt.
DIFF="$(git diff --name-status "$BASE_SHA..$TARGET_SHA" -- "$MIG_DIR")"
ADDED=""; TAMPERED=""
while IFS=$'\t' read -r status path _; do
  [ -n "$status" ] || continue
  name="$(basename "$path")"
  [ "$name" = "MIGRATIONS.md" ] && continue
  case "$status" in
    A*) ADDED="$ADDED $name" ;;
    *)  TAMPERED="$TAMPERED $name($status)" ;;
  esac
done <<EOF
$DIFF
EOF

if [ -n "$TAMPERED" ]; then
  log "DB_APPLY_REFUSED: range modifies or deletes existing migrations:$TAMPERED - append-only was violated; a human decides"
  [ "$MODE" = "dry-run" ] || factory_notify "db-apply" "range $BASE_SHA..$TARGET_SHA edits applied migration files:$TAMPERED - this should be impossible past the gate. Nothing was applied."
  exit 1
fi
ADDED="$(echo "$ADDED" | tr ' ' '\n' | grep . | sort || true)"
if [ -z "$ADDED" ]; then
  log "DB_APPLY_NONE range=$BASE_SHA..$TARGET_SHA"
  exit 0
fi
N_FILES="$(echo "$ADDED" | grep -c .)"
log "DB_APPLY_PLAN files=$N_FILES range=$BASE_SHA..$TARGET_SHA"

# --- rung 1: the static policy, per file FROM THE MERGED SHA ---------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dbapply-$RUN_TS.XXXXXX")"
ESCALATED=""; FLOORED=""
for name in $ADDED; do
  git show "$TARGET_SHA:$MIG_DIR/$name" > "$WORK/$name" \
    || { log "DB_APPLY_REFUSED: cannot read $name at $TARGET_SHA"; exit 1; }
  python3 "$POLICY" --json "$WORK/$name" > "$WORK/$name.policy" 2>/dev/null || true
  python3 "$POLICY" "$WORK/$name" > "$WORK/$name.verdict" 2>&1 || true
  VERDICT="$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print("floor" if d["floor"] else ("allow" if d["allow"] else "judge"))' "$WORK/$name.policy")"
  case "$VERDICT" in
    allow) log "DB_POLICY_ALLOW file=$name" ;;
    judge) ESCALATED="$ESCALATED $name"; log "DB_POLICY_ESCALATE file=$name -> the migration judge" ;;
    floor) FLOORED="$FLOORED $name"; log "DB_POLICY_FLOOR file=$name -> a human, always" ;;
  esac
  sed 's/^/    /' "$WORK/$name.verdict" | tee -a "$RUN_LOG"
done

# --- rung 3 first, because it vetoes everything: the human floor -----------------
if [ -n "$FLOORED" ]; then
  DETAIL="$(grep -h 'DB_POLICY_ESCALATE_FLOOR' "$WORK"/*.verdict 2>/dev/null | head -8 | tr '\n' ';' | head -c 700)"
  log "DB_APPLY_ESCALATED floor files:$FLOORED"
  [ "$MODE" = "dry-run" ] || factory_notify "db-apply" "migration range $BASE_SHA..$TARGET_SHA parked for you - these files hit the HUMAN FLOOR (data destruction or the money/identity schemas; the judge never rules here):$FLOORED :: $DETAIL :: Apply via MCP apply_migration + verify (.claude/skills/vox-database-migrations/SKILL.md), then re-run factory/deploy.sh - the next tick's catch-up also retries. Nothing was applied; the deploy pointer has not moved. Evidence: $RUN_LOG"
  rm -rf "$WORK"
  exit 1
fi

if [ "$MODE" = "dry-run" ]; then
  [ -z "$ESCALATED" ] \
    && log "DRY_RUN: every file passes the policy - a real run would apply$(echo; echo "$ADDED" | sed 's/^/    /')" \
    || log "DRY_RUN: a real run would consult the migration judge for:$ESCALATED (park-by-default) and apply the rest"
  rm -rf "$WORK"
  exit 0
fi

api_setup || exit 1

# --- live guard: replacing a function prod's policies lean on goes to the judge --
for name in $ADDED; do
  python3 "$POLICY" --probes "$WORK/$name" > "$WORK/$name.probes" 2>/dev/null || echo '[]' > "$WORK/$name.probes"
  FNS="$(python3 -c 'import json,sys
for p in json.load(open(sys.argv[1])):
    w = p.get("md5_watch")
    if w: print((w["schema"] or "public") + "." + w["fn"])' "$WORK/$name.probes" 2>/dev/null || true)"
  for qual in $FNS; do
    fn="${qual##*.}"
    OUT="$WORK/guard-$fn.json"
    api_sql "select coalesce((select count(*) from pg_policies where qual ilike '%${fn}%' or with_check ilike '%${fn}%'),0) as pol_refs, coalesce((select bool_or(prosecdef) from pg_proc where proname='${fn}'),false) as is_secdef" "$OUT" \
      || { log "DB_APPLY_REFUSED: could not run the function-replace guard for $fn"; factory_notify "db-apply" "range $BASE_SHA..$TARGET_SHA: the function-replace guard could not run (API error) - nothing was applied. $RUN_LOG"; exit 1; }
    GUARD="$(python3 -c 'import json,sys
r = json.load(open(sys.argv[1]))
row = r[0] if isinstance(r, list) and r else {}
print("judge" if (row.get("pol_refs", 0) or row.get("is_secdef")) else "ok")' "$OUT")"
    if [ "$GUARD" != "ok" ]; then
      case " $ESCALATED " in *" $name "*) : ;; *) ESCALATED="$ESCALATED $name" ;; esac
      log "DB_GUARD_TRIP file=$name fn=$fn is policy-referenced or SECURITY DEFINER in prod -> the migration judge"
      cp "$OUT" "$WORK/$name.guard.json" 2>/dev/null || true
    fi
  done
done

# --- rung 2: the migration judge, park-by-default --------------------------------
JUDGE_VERDICT="$WORK/judge-verdict.json"
if [ -n "$ESCALATED" ]; then
  log "DB_JUDGE_START files:$ESCALATED model=$JUDGE_MODEL"
  # Live facts for the judge: row counts (lock risk is a function of size) plus any
  # guard trips. Facts are gathered BY THE MACHINERY — the judge gets evidence, not
  # network access.
  FACTS="$WORK/facts.json"
  api_sql "select schemaname||'.'||relname as tbl, n_live_tup from pg_stat_user_tables where schemaname in ('vox','public') order by n_live_tup desc limit 40" "$FACTS" \
    || echo '[]' > "$FACTS"
  python3 - "$WORK" "$JUDGE_PROMPT" "$BASE_SHA..$TARGET_SHA" "$JUDGE_VERDICT" $ESCALATED <<'PY'
import json, sys
work, prompt_path, rng, verdict_path, *files = sys.argv[1:]
files_block, verdicts_block = [], []
for f in files:
    files_block.append(f"### {f}\n```sql\n{open(f'{work}/{f}', encoding='utf-8').read()}\n```")
    pol = json.load(open(f"{work}/{f}.policy"))
    concerns = [v for v in pol["verdicts"] if not v["allow"]]
    try:
        guard = open(f"{work}/{f}.guard.json").read().strip()
        concerns.append({"class": "live_guard", "why": f"prod facts: {guard}", "stmt": ""})
    except FileNotFoundError:
        pass
    verdicts_block.append(f"### {f}\n" + "\n".join(
        f"- [{c['class']}] {c['why']} :: {c['stmt'][:100]}" for c in concerns)
        if concerns else f"### {f}\n- (allowed by the policy; sent to you by the live guard)")
try:
    facts = open(f"{work}/facts.json").read()
except FileNotFoundError:
    facts = "[]"
text = open(prompt_path, encoding="utf-8").read()
text = (text.replace("{{RANGE}}", rng)
            .replace("{{VERDICT_PATH}}", verdict_path)
            .replace("{{FILES_BLOCK}}", "\n\n".join(files_block))
            .replace("{{VERDICTS_BLOCK}}", "\n\n".join(verdicts_block))
            .replace("{{FACTS_BLOCK}}", f"Row counts (prod):\n```json\n{facts}\n```"))
open(f"{work}/judge-prompt.md", "w", encoding="utf-8").write(text)
PY
  HOLDOUT_DENY=""
  [ -d "${FACTORY_HOLDOUT_DIR:-.factory/holdout}" ] && HOLDOUT_DENY="--disallowedTools Read(${FACTORY_HOLDOUT_DIR:-.factory/holdout}/**)"
  if ! "$FACTORY_AGENT" -p "$(cat "$WORK/judge-prompt.md")" \
        --model "$JUDGE_MODEL" \
        --allowedTools "Read,Write" \
        $HOLDOUT_DENY \
        --permission-mode acceptEdits \
        --add-dir "$WORK" \
        --max-budget-usd "$JUDGE_BUDGET" \
        --output-format json \
        > "$WORK/judge-agent.json" 2> "$WORK/judge-agent.err"; then
    log "DB_JUDGE_FAILED agent exited non-zero - fail-closed, the range parks; see $WORK/judge-agent.err"
  fi
  # Fail-closed parse: verdict must exist, parse, say "apply", cover EXACTLY the
  # escalated set, rule apply on every file, and give every file verify_sql (or a
  # derivable probe). verify_sql must be read-only SELECTs. Anything else = park.
  JUDGE_OK="$(python3 - "$JUDGE_VERDICT" "$WORK" $ESCALATED <<'PY' 2>/dev/null || echo park
import json, sys
path, work, *files = sys.argv[1:]
try:
    d = json.load(open(path))
    assert d.get("verdict") == "apply"
    assert sorted(d.get("files_reviewed", [])) == sorted(files)
    rulings = d.get("rulings") or []
    assert rulings and all(r.get("ruling") == "apply" for r in rulings)
    assert {r.get("file") for r in rulings} >= set(files)
    vs = d.get("verify_sql") or {}
    for f in files:
        sqls = vs.get(f) or []
        assert all(isinstance(s, str) and s.strip().lower().startswith("select") for s in sqls)
        static = json.load(open(f"{work}/{f}.probes"))
        assert sqls or static, f"{f}: no verify_sql and no derivable probe"
    print("apply")
except Exception:
    print("park")
PY
)"
  cp "$JUDGE_VERDICT" "$EVIDENCE_DIR/$RUN_TS-judge.json" 2>/dev/null || true
  if [ "$JUDGE_OK" != "apply" ]; then
    SUMMARY="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("summary","(no verdict written)")[:400])
except Exception: print("(no verdict written)")' "$JUDGE_VERDICT")"
    log "DB_JUDGE_PARK files:$ESCALATED - $SUMMARY"
    factory_notify "db-apply" "migration range $BASE_SHA..$TARGET_SHA parked by the MIGRATION JUDGE:$ESCALATED :: $SUMMARY :: Apply via MCP apply_migration + verify (.claude/skills/vox-database-migrations/SKILL.md), then re-run factory/deploy.sh - the next tick's catch-up also retries. Nothing was applied; the deploy pointer has not moved. Judge verdict: $EVIDENCE_DIR/$RUN_TS-judge.json; log: $RUN_LOG"
    exit 1
  fi
  # Merge the judge's verification demands into each file's probe list.
  for name in $ESCALATED; do
    python3 - "$JUDGE_VERDICT" "$WORK/$name.probes" "$name" <<'PY'
import json, sys
verdict, probes_path, name = sys.argv[1:4]
probes = json.load(open(probes_path))
for s in (json.load(open(verdict)).get("verify_sql") or {}).get(name, []):
    probes.append({"kind": "judge", "name": f"judge:{name}", "sql": s})
json.dump(probes, open(probes_path, "w"))
PY
  done
  log "DB_JUDGE_CLEARED files:$ESCALATED - $(python3 -c 'import json,sys
print(json.load(open(sys.argv[1])).get("summary","")[:300])' "$JUDGE_VERDICT")"
fi

# --- apply each file, in file order, verify each before the next -----------------
APPLIED=0
for name in $ADDED; do
  base_name="${name%.sql}"
  EVIDENCE="$EVIDENCE_DIR/$RUN_TS-$base_name.json"

  # Already recorded remotely (a retried tick, or a human raced us): skip the apply,
  # still verify the objects — the skill's own rule for already-applied migrations.
  OUT="$WORK/pre-$base_name.json"
  api_sql "select count(*) as n from supabase_migrations.schema_migrations where name='${base_name}'" "$OUT" \
    || { log "DB_APPLY_FAILED: cannot read remote migration history"; factory_notify "db-apply" "range $BASE_SHA..$TARGET_SHA: cannot read supabase_migrations.schema_migrations - nothing further applied. $RUN_LOG"; exit 1; }
  KNOWN="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r[0]["n"] if r else 0)' "$OUT")"

  # Pre-capture definition md5s for functions this file replaces (evidence trail).
  PRE_MD5="$WORK/md5-pre-$base_name.json"
  api_sql "select p.proname, md5(pg_get_functiondef(p.oid)) as md5 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('vox','public')" "$PRE_MD5" >/dev/null 2>&1 || echo '[]' > "$PRE_MD5"

  if [ "$KNOWN" = "0" ]; then
    BODY="$WORK/apply-$base_name.json"
    python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "query": open(sys.argv[2], encoding="utf-8").read()}))' \
      "$base_name" "$WORK/$name" > "$BODY"
    OUT="$WORK/applyres-$base_name.json"
    CODE="$(curl -sS -o "$OUT" -w '%{http_code}' --max-time 600 -X POST \
            -H @"$HDR_FILE" -H 'Content-Type: application/json' \
            -H "Idempotency-Key: db-apply-$TARGET_SHA-$base_name" \
            --data-binary @"$BODY" "$API/database/migrations" 2>>"$RUN_LOG" || echo 000)"
    case "$CODE" in
      2??) log "DB_APPLY_FN_OK file=$name http=$CODE" ;;
      *)   ERR="$(head -c 500 "$OUT" 2>/dev/null || true)"
           log "DB_APPLY_FAILED file=$name http=$CODE error=$ERR"
           cp "$OUT" "$EVIDENCE" 2>/dev/null || true
           factory_notify "db-apply" "PROD MIGRATION FAILED: $name (HTTP $CODE) in range $BASE_SHA..$TARGET_SHA. SQL error: $ERR :: Files before it applied and verified clean ($APPLIED); DDL is never auto-rolled-back - the schema state is exactly as the evidence shows. The deploy pointer has NOT moved and no EF deployed. Evidence: $EVIDENCE and $RUN_LOG"
           exit 1 ;;
    esac
  else
    log "DB_APPLY_SKIP file=$name already recorded remotely - verifying objects only"
  fi

  # --- verify: history row + every probe (static + judge's); empty is not pass ---
  OUT="$WORK/hist-$base_name.json"
  api_sql "select version, name from supabase_migrations.schema_migrations where name='${base_name}'" "$OUT" \
    || { log "DB_APPLY_FAILED: history re-read failed after applying $name"; factory_notify "db-apply" "$name applied but the history row could not be re-read - VERIFY BY HAND before anything deploys. $RUN_LOG"; exit 1; }
  RECORDED="$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r[0]["version"] if r else "")' "$OUT")"
  [ -n "$RECORDED" ] \
    || { log "DB_APPLY_FAILED: $name ran but no history row exists under name=$base_name"; factory_notify "db-apply" "$name: the apply returned success but supabase_migrations has no row named $base_name - the recording contract broke. VERIFY BY HAND. $RUN_LOG"; exit 1; }
  log "DB_APPLY_RECORDED file=$name version=$RECORDED"

  N_PROBES="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$WORK/$name.probes")"
  [ "$N_PROBES" -gt 0 ] || { log "DB_APPLY_FAILED: zero probes for $name - empty is not pass"; exit 1; }
  P_OK=0
  while IFS= read -r probe_sql; do
    [ -n "$probe_sql" ] || continue
    OUT="$WORK/probe-$base_name-$P_OK.json"
    if api_sql "$probe_sql" "$OUT" && python3 -c 'import json,sys
r = json.load(open(sys.argv[1])); sys.exit(0 if (r and r[0].get("ok") is True) else 1)' "$OUT"; then
      P_OK=$((P_OK + 1))
    else
      log "DB_APPLY_FAILED: probe returned false for $name :: $probe_sql"
      factory_notify "db-apply" "PROD VERIFY FAILED after applying $name: an expected observable is not there ($probe_sql). DDL is never auto-rolled-back; the deploy pointer has NOT moved. Evidence: $EVIDENCE and $RUN_LOG"
      exit 1
    fi
  done <<EOF
$(python3 -c 'import json,sys
for p in json.load(open(sys.argv[1])): print(p["sql"])' "$WORK/$name.probes")
EOF

  # Post-capture md5s; the pre/post pair rides the evidence file (Portal-1.5 trail).
  POST_MD5="$WORK/md5-post-$base_name.json"
  api_sql "select p.proname, md5(pg_get_functiondef(p.oid)) as md5 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('vox','public')" "$POST_MD5" >/dev/null 2>&1 || echo '[]' > "$POST_MD5"

  python3 - "$EVIDENCE" "$name" "$RECORDED" "$WORK/$name.probes" "$PRE_MD5" "$POST_MD5" <<'PY'
import json, sys
ev, name, version, probes, pre, post = sys.argv[1:7]
def j(p):
    try: return json.load(open(p))
    except Exception: return []
json.dump({"file": name, "version": version, "range_probes": j(probes),
           "fn_md5_pre": {r["proname"]: r["md5"] for r in j(pre) if isinstance(r, dict)},
           "fn_md5_post": {r["proname"]: r["md5"] for r in j(post) if isinstance(r, dict)}},
          open(ev, "w"), indent=1)
PY
  log "DB_APPLY_VERIFIED file=$name probes=$N_PROBES evidence=$EVIDENCE"
  echo "$(date -u +%FT%TZ) apply $name version=$RECORDED probes=$N_PROBES" >> "$DB_HISTORY"
  APPLIED=$((APPLIED + 1))
done

rm -rf "$WORK"
log "DB_APPLY_OK files=$APPLIED range=$BASE_SHA..$TARGET_SHA"
