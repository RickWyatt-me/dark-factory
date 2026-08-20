#!/usr/bin/env bash
# The evolution auto-apply channel — FACTORY_RULES 9b (Rick's directive, 2026-08-18:
# "autonomously get the evolution pass operating properly").
#
# evolve.sh proposes; THIS script is the narrow, judged channel that applies the
# PROMPT-ONLY subset of those proposals without a human keystroke:
#
#   rung 1: factory/evolve_apply_policy.py — deterministic. Eligible = exactly one
#           file under factory/prompts/*.md, ready-to-apply snippet, status line
#           exactly "- [ ] proposed". Everything else (gate, guard, runner,
#           orchestrator, governance, holdout, the DB judge's prompts, THIS channel's
#           own prompts, evolve's own prompts) is the floor: human commit, always.
#   rung 2: an applier agent makes the one edit; deterministic post-checks (single
#           file changed, no unrendered placeholder, diff cap, not gutted).
#   rung 3: the INDEPENDENT EVOLUTION-APPLY JUDGE (premium model, park-by-default,
#           one-way authority) rules on the diff. Park = the edit is reverted and the
#           block is annotated for human review. Missing/malformed verdict = park.
#
# An applied edit commits directly on develop as factory bookkeeping
# ("evolve(prompts): ...") and pushes — the tree a tick runs is always a committed
# tree. Evidence per attempt in .factory/evolution/applied/<ts>-<slug>/. Rick is
# notified either way. A subsequent lap that parks in a node whose prompt 9b changed
# names the 9b commit in its diagnosis; reverting is a human call (git revert).
#
#   bash factory/evolve-apply.sh --catch-up      process eligible blocks (the tick's call)
#   bash factory/evolve-apply.sh --dry-run       list what would apply, change nothing

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# shellcheck source=factory/config.sh
. "$ROOT/factory/config.sh"

POLICY="factory/evolve_apply_policy.py"
APPDIR=".factory/evolution/applied"
MODEL_APPLIER="${FACTORY_EVOLVE_MODEL:-$FACTORY_MODEL_CHEAP}"
MODEL_JUDGE="${FACTORY_EVOLVE_APPLY_MODEL:-$FACTORY_MODEL_PREMIUM}"
BUDGET="${FACTORY_EVOLVE_APPLY_BUDGET:-3}"
MAX_PER_PASS="${FACTORY_EVOLVE_APPLY_MAX:-3}"
DIFF_CAP="${FACTORY_EVOLVE_APPLY_DIFF_CAP:-40}"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

trap 'echo "[$(date -u +%FT%TZ)] EVOLVE_APPLY_FAULT line $LINENO exited $? running: $BASH_COMMAND - nothing after this ran; the next --catch-up retries"' ERR

if [ -f "$FACTORY_STOP_FILE" ]; then
  log "STOPPED: $FACTORY_STOP_FILE present. Remove it to resume."
  exit 0
fi

if [ "${FACTORY_EVOLVE_APPLY_ENABLED:-1}" != "1" ]; then
  log "EVOLVE_APPLY_DISABLED (FACTORY_EVOLVE_APPLY_ENABLED != 1) - proposals stay proposed"
  exit 0
fi

DRY_RUN=0
case "${1:-}" in
  --catch-up) ;;
  --dry-run)  DRY_RUN=1 ;;
  *) echo "usage: evolve-apply.sh --catch-up | --dry-run"; exit 1 ;;
esac

# A dirty prompt tree means a human (or a fault) is mid-edit: refuse rather than
# commit someone else's half-work as ours. Same for the ledger itself.
if [ -n "$(git status --porcelain -- factory/prompts .factory/evolution/RECOMMENDATIONS.md)" ]; then
  log "EVOLVE_APPLY_REFUSED: factory/prompts or RECOMMENDATIONS.md has uncommitted changes - a 9b commit must contain only its own edit"
  exit 0
fi

ELIGIBLE_JSON="$(python3 "$POLICY" --list)"
COUNT="$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$ELIGIBLE_JSON")"
if [ "$COUNT" -eq 0 ]; then
  log "EVOLVE_APPLY_NONE: no eligible pending prompt recommendations"
  exit 0
fi
log "EVOLVE_APPLY_PLAN eligible=$COUNT cap_per_pass=$MAX_PER_PASS"
if [ "$DRY_RUN" -eq 1 ]; then
  python3 -c 'import json,sys
for b in json.loads(sys.argv[1]):
    print(f"  would apply: {b[\"file\"]} <- {b[\"title\"]}")' "$ELIGIBLE_JSON"
  exit 0
fi

HOLDOUT_DENY="Read($FACTORY_HOLDOUT_DIR/**) Glob($FACTORY_HOLDOUT_DIR/**) Grep($FACTORY_HOLDOUT_DIR/**)"

APPLIED=0
i=0
while [ "$i" -lt "$COUNT" ] && [ "$APPLIED" -lt "$MAX_PER_PASS" ]; do
  FILE="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])]["file"])' "$ELIGIBLE_JSON" "$i")"
  TITLE="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])]["title"])' "$ELIGIBLE_JSON" "$i")"
  START="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[int(sys.argv[2])]["start_line"])' "$ELIGIBLE_JSON" "$i")"
  i=$((i + 1))

  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  SLUG="$(echo "$TITLE" | tr -cs 'a-zA-Z0-9' '-' | tr 'A-Z' 'a-z' | cut -c1-48)"
  WORK="$APPDIR/$TS-$SLUG"
  mkdir -p "$WORK"
  WORK_REAL="$(cd "$WORK" && pwd -P)"

  # The block, byte-exact, from its line span in the ledger.
  python3 - "$START" > "$WORK/block.md" <<'PY'
import sys
from pathlib import Path
start = int(sys.argv[1]) - 1
lines = Path(".factory/evolution/RECOMMENDATIONS.md").read_text(encoding="utf-8").splitlines()
end = next((j for j in range(start + 1, len(lines)) if lines[j].startswith("## ")), len(lines))
print("\n".join(lines[start:end]))
PY
  cp "$FILE" "$WORK/target.old.md"
  log "EVOLVE_APPLY_START file=$FILE :: $TITLE (evidence $WORK)"

  # --- the applier ------------------------------------------------------------
  python3 - "$WORK" "$FILE" <<'PY'
import sys
from pathlib import Path
work, file = sys.argv[1], sys.argv[2]
text = Path("factory/evolve-apply-prompts/applier.md").read_text(encoding="utf-8")
text = (text.replace("{{BLOCK}}", Path(f"{work}/block.md").read_text(encoding="utf-8"))
            .replace("{{FILE}}", file))
Path(f"{work}/applier-prompt.md").write_text(text, encoding="utf-8")
PY
  # shellcheck disable=SC2086 -- HOLDOUT_DENY is a deliberate word list
  if ! "$FACTORY_AGENT" -p "$(cat "$WORK/applier-prompt.md")" \
        --model "$MODEL_APPLIER" \
        --allowedTools "Read Edit($FILE)" \
        --disallowedTools $HOLDOUT_DENY \
        --permission-mode acceptEdits \
        --add-dir "$ROOT" \
        --max-budget-usd "$BUDGET" \
        --output-format json \
        > "$WORK/applier-agent.json" 2> "$WORK/applier-agent.err"; then
    log "EVOLVE_APPLY_PARK file=$FILE - applier agent failed; see $WORK/applier-agent.err"
    git checkout -- "$FILE"
    python3 "$POLICY" --mark "$START" "- [ ] proposed (auto-apply parked $(date -u +%F): applier failed; human review - $WORK)" >/dev/null || true
    factory_notify "evolve-apply" "9b PARK (applier failed): $TITLE -> $FILE reverted, block annotated for human review. Evidence: $WORK"
    continue
  fi

  # --- deterministic post-checks (rung 2's gate half) -------------------------
  CHANGED_FILES="$(git diff --name-only)"
  CHANGED_LINES="$(git diff --numstat -- "$FILE" | awk '{print $1 + $2}')"
  VIOLATION=""
  if [ -z "$CHANGED_FILES" ]; then
    VIOLATION="the applier changed nothing (anchor not found, or a silent refusal)"
  elif [ "$CHANGED_FILES" != "$FILE" ]; then
    VIOLATION="files beyond the target changed: $(echo "$CHANGED_FILES" | tr '\n' ' ')"
  elif ! FACTORY_EVOLVE_APPLY_DIFF_CAP="$DIFF_CAP" python3 "$POLICY" --check "$WORK/target.old.md" "$FILE" "${CHANGED_LINES:-0}" > "$WORK/policy-check.txt" 2>&1; then
    VIOLATION="policy check failed: $(cat "$WORK/policy-check.txt" | tr '\n' ' ')"
  fi
  if [ -n "$VIOLATION" ]; then
    log "EVOLVE_APPLY_PARK file=$FILE - $VIOLATION"
    git checkout -- . 2>/dev/null || true
    python3 "$POLICY" --mark "$START" "- [ ] proposed (auto-apply parked $(date -u +%F): $VIOLATION - human review; $WORK)" >/dev/null || true
    factory_notify "evolve-apply" "9b PARK (deterministic check): $TITLE :: $VIOLATION :: edit reverted, block annotated. Evidence: $WORK"
    continue
  fi
  git diff -- "$FILE" > "$WORK/target.diff"

  # --- the independent judge --------------------------------------------------
  VERDICT="$WORK_REAL/verdict.json"
  python3 - "$WORK_REAL" "$FILE" "$VERDICT" <<'PY'
import sys
from pathlib import Path
work, file, verdict = sys.argv[1], sys.argv[2], sys.argv[3]
text = Path("factory/evolve-apply-prompts/judge.md").read_text(encoding="utf-8")
text = (text.replace("{{WORKDIR}}", work)
            .replace("{{FILE}}", file)
            .replace("{{VERDICT_PATH}}", verdict))
Path(f"{work}/judge-prompt.md").write_text(text, encoding="utf-8")
PY
  # shellcheck disable=SC2086
  if ! "$FACTORY_AGENT" -p "$(cat "$WORK/judge-prompt.md")" \
        --model "$MODEL_JUDGE" \
        --allowedTools "Read,Write" \
        --disallowedTools $HOLDOUT_DENY \
        --permission-mode acceptEdits \
        --add-dir "$ROOT" --add-dir "$WORK_REAL" \
        --max-budget-usd "$BUDGET" \
        --output-format json \
        > "$WORK/judge-agent.json" 2> "$WORK/judge-agent.err"; then
    log "EVOLVE_APPLY_JUDGE_FAILED - fail-closed, the edit parks; see $WORK/judge-agent.err"
  fi
  RULING="$(python3 - "$VERDICT" "$FILE" <<'PY' 2>/dev/null || echo park
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert d.get("verdict") == "apply"
    assert d.get("file") == sys.argv[2]
    print("apply")
except Exception:
    print("park")
PY
)"
  SUMMARY="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get("summary","")[:300])
except Exception: print("(no verdict written)")' "$VERDICT" 2>/dev/null || echo "?")"

  if [ "$RULING" != "apply" ]; then
    log "EVOLVE_APPLY_JUDGE_PARK file=$FILE :: $SUMMARY"
    git checkout -- "$FILE"
    python3 "$POLICY" --mark "$START" "- [ ] proposed (auto-apply parked $(date -u +%F) by the 9b judge: human review - $WORK)" >/dev/null || true
    factory_notify "evolve-apply" "9b PARK (judge): $TITLE :: $SUMMARY :: edit reverted, block annotated. Verdict: $WORK/verdict.json"
    continue
  fi

  # --- apply = commit + push (factory bookkeeping; the tick runs committed trees)
  python3 "$POLICY" --mark "$START" "- [x] auto-applied $(date -u +%F) (FACTORY_RULES 9b: policy checks + evolution-apply judge; evidence $WORK)" >/dev/null \
    || { log "EVOLVE_APPLY_PARK file=$FILE - could not mark the ledger; reverting"; git checkout -- "$FILE"; continue; }
  git add "$FILE" .factory/evolution/RECOMMENDATIONS.md
  git commit -q \
    -m "evolve(prompts): $(printf '%.60s' "$TITLE") (9b auto-apply)" \
    -m "Applied by factory/evolve-apply.sh: policy checks clean, evolution-apply judge ruled apply. Evidence: $WORK

Epic: factory
Story: evolve-9b
Type: evolve
Learning: $SUMMARY
Affected: $FILE"
  git push -q origin HEAD || log "EVOLVE_APPLY_PUSH_FAILED - committed locally; the next push carries it"
  APPLIED=$((APPLIED + 1))
  log "EVOLVE_APPLY_OK file=$FILE commit=$(git rev-parse --short HEAD) :: $SUMMARY"
  factory_notify "evolve-apply" "9b APPLIED: $TITLE -> $FILE (commit $(git rev-parse --short HEAD)). Judge: $SUMMARY. Evidence: $WORK"
done

log "EVOLVE_APPLY_DONE applied=$APPLIED of $COUNT eligible"
