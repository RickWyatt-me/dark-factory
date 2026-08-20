#!/usr/bin/env bash
# The post-merge evolution loop — dark-factory program Phase G, dossier 04 §3.
#
# The harness's promotion ladder (caught bug -> guard/lesson), reborn for the factory:
# after a lap is DECIDED — merged to develop, or parked needs-human — one cheap agent
# session reviews the lap's PROCESS from its run artifacts and writes recommendations.
# It gates nothing, blocks nothing, and runs outside every lap's critical path; a lap
# that never gets evolved is a lost lesson, not a stuck queue.
#
#   bash factory/evolve.sh 17                 review the lap for issue 17
#   bash factory/evolve.sh --catch-up         review every decided, un-reviewed lap
#   bash factory/evolve.sh --window 30        proactive scan across the last 30 days
#   ... --dry-run                             say what would run, run nothing
#
# THE ONE RULE THAT MAKES THIS SAFE TO AUTOMATE: the evolve session CHANGES NOTHING.
# Its recommendations land in .factory/evolution/ as proposals, and applying one is a
# human commit — the factory may not edit the rules it is judged by (FACTORY_RULES).
# That is enforced structurally, not by the prompt: the agent's Write/Edit allowlist
# covers .factory/evolution/** and nothing else, and the holdout stays tool-denied.
#
# Everything here is derived from git and files on disk — never from the GitHub API.
# The day this was built, the API rate limit was exhausted and every `gh` call on the
# machine failed; a reflection step that dies with the network is a reflection step
# that quietly stops happening.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# shellcheck source=factory/config.sh
. "$ROOT/factory/config.sh"

RUNS=".factory/runs"
# The physical path behind the symlink (iCloud shield): the agent's sandbox denies
# writes AND reads outside its --add-dir set, and the symlink's target is outside the
# repo. Phase D lap 2 finding A, same class.
RUNS_REAL="$(cd "$RUNS" 2>/dev/null && pwd -P)" || {
  echo "EVOLVE_REFUSED: $RUNS does not resolve - nothing has ever run"; exit 1; }

EVODIR=".factory/evolution"
RECS="$EVODIR/RECOMMENDATIONS.md"
MODEL="${FACTORY_EVOLVE_MODEL:-$FACTORY_MODEL_CHEAP}"
BUDGET="${FACTORY_EVOLVE_BUDGET:-3}"
HOLDOUT_DENY="Read($FACTORY_HOLDOUT_DIR/**) Glob($FACTORY_HOLDOUT_DIR/**) Grep($FACTORY_HOLDOUT_DIR/**)"
# Write/Edit are scoped to the output dir; git access is prefix-matched read-only
# archaeology. No gh, no push, no state.py.
EVOLVE_TOOLS="Read Glob Grep Bash(git log:*) Bash(git show:*) Bash(git diff:*) Write($EVODIR/**) Edit($EVODIR/**)"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# The same backstop every factory script carries: under `set -e` an unguarded failure
# ends the script at that line, and a reflection step that dies silently just stops
# reflecting. Nothing to park and nothing to notify — a missed review re-runs on the
# next `--catch-up` — but the ending must say where it happened.
trap 'echo "[$(date -u +%FT%TZ)] EVOLVE_FAULT line $LINENO exited $? running: $BASH_COMMAND - nothing after this ran; the next --catch-up retries"' ERR

# The stop button. The LOCAL half only, on purpose: evolve dispatches no work and
# touches no queue, so the remote label (which needs the API) is not consulted — see
# the API note above. The file is still absolute: STOP means nothing runs.
if [ -f "$FACTORY_STOP_FILE" ]; then
  log "STOPPED: $FACTORY_STOP_FILE present. Remove it to resume."
  exit 0
fi

DRY_RUN=0
MODE=""
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --catch-up) MODE="catchup" ;;
    --window)   MODE="window"; ARG="${2:?--window needs a day count}"; shift ;;
    gh:issue:*) MODE="one"; ARG="${1#gh:issue:}" ;;
    [0-9]*)     MODE="one"; ARG="$1" ;;
    *) echo "usage: evolve.sh <issue-number> | --catch-up | --window <days> [--dry-run]"; exit 1 ;;
  esac
  shift
done
[ -z "$MODE" ] && { echo "usage: evolve.sh <issue-number> | --catch-up | --window <days> [--dry-run]"; exit 1; }

mkdir -p "$EVODIR"

# --- lap plumbing, all file/git-derived --------------------------------------

# Every run dir materializes its issue as issue.md with front-matter `id: gh:issue:N`
# (state.py body). That one line is the join key for the whole loop.
runs_for_issue() {      # runs_for_issue <n>  -> run dir paths, oldest first
  grep -l "^id: gh:issue:$1\$" "$RUNS"/*/issue.md 2>/dev/null \
    | sed 's|/issue.md$||' | sort
}

issues_with_runs() {    # -> every issue number that has at least one run
  # `|| true` inside the pipe head: a factory with no runs yet is empty, not broken.
  { grep -h '^id: gh:issue:' "$RUNS"/*/issue.md 2>/dev/null || true; } \
    | sed 's/^id: gh:issue://' | sort -un
}

# A lap is DECIDED when its squash is on origin/develop (merge.sh writes the literal
# line `Issue: gh:issue:N` into every squash body) or when its issue/PR appears in the
# needs-human ledger. An undecided lap is still someone else's work in flight.
lap_outcome() {         # lap_outcome <n>  -> "merged <sha>" | "parked needs-human" | ""
  local n="$1" sha pr
  sha="$(git log origin/develop -1 --format='%h' --grep="^Issue: gh:issue:$n\$" 2>/dev/null || true)"
  if [ -n "$sha" ]; then echo "merged $sha"; return 0; fi
  pr="$(cat "$(runs_for_issue "$n" | head -1)/pr.url" 2>/dev/null | grep -o '[0-9]*$' || true)"
  if grep -q "gh:issue:$n\b" .factory/needs-human.md 2>/dev/null \
     || { [ -n "$pr" ] && grep -q "gh:pr:$pr\b" .factory/needs-human.md 2>/dev/null; }; then
    echo "parked needs-human"; return 0
  fi
  echo ""
}

lap_cost() {            # lap_cost <n>  -> summed cost_usd across the lap's run records
  local n="$1" jsons=""
  local d
  for d in $(runs_for_issue "$n"); do
    [ -f "$d.json" ] && jsons="$jsons $d.json"
  done
  # shellcheck disable=SC2086 -- word-split on purpose
  python3 - $jsons <<'PY'
import json, sys
total = 0.0
for p in sys.argv[1:]:
    try:
        total += float(json.load(open(p)).get("cost_usd") or 0)
    except (OSError, ValueError):
        pass
print(f"{total:.2f}")
PY
}

# --- the one agent session ---------------------------------------------------

render() {              # render <template> <out> <sed-args...>
  local tpl="$1" out="$2"; shift 2
  sed "$@" "$tpl" > "$out"
  # An unrendered placeholder is a prompt that lies (run-workflow.sh, same check):
  # the agent is handed a path that was never filled in and reasons from nothing.
  if grep -qE '\{\{[a-z_]+\}\}' "$out"; then
    log "EVOLVE_FAILED unrendered placeholder(s) in $out: $(grep -ohE '\{\{[a-z_]+\}\}' "$out" | sort -u | tr '\n' ' ')"
    return 1
  fi
}

invoke() {              # invoke <rendered-prompt> <outdir> <must-exist-artifact>
  local rendered="$1" outdir="$2" artifact="$3"
  # shellcheck disable=SC2086 -- HOLDOUT_DENY is a deliberate word list
  if ! "$FACTORY_AGENT" -p "$(cat "$rendered")" \
        --model "$MODEL" \
        --allowedTools "$EVOLVE_TOOLS" \
        --disallowedTools $HOLDOUT_DENY \
        --permission-mode acceptEdits \
        --add-dir "$ROOT" --add-dir "$RUNS_REAL" \
        --max-budget-usd "$BUDGET" \
        --output-format json \
        > "$outdir/agent.json" 2> "$outdir/agent.err"; then
    log "EVOLVE_FAILED agent exited non-zero; see $outdir/agent.err"
    tail -5 "$outdir/agent.err" | sed 's/^/    /'
    return 1
  fi
  # EMPTY IS NOT PASS: an agent can exit 0 having written nothing (tool denied, budget
  # hit, refused). The artifact is the proof the session happened.
  if [ ! -s "$artifact" ]; then
    log "EVOLVE_FAILED the session exited 0 but never wrote $artifact"
    return 1
  fi
  local spent
  spent="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("total_cost_usd","?"))' "$outdir/agent.json" 2>/dev/null || echo "?")"
  log "EVOLVE_OK $artifact (cost \$$spent, model $MODEL)"
}

evolve_one() {          # evolve_one <issue-number>
  # Two statements, not one: bash expands every word of a `local` line BEFORE the
  # builtin assigns, so `local n="$1" outdir=...$n` reads n while it is still unset
  # (set -u aborts; caught live on this script's first single-issue run).
  local n="$1"
  local outdir="$EVODIR/issue-$n"
  local outcome; outcome="$(lap_outcome "$n")"
  if [ -z "$outcome" ]; then
    log "SKIP issue $n - lap not decided yet (no squash on origin/develop, not in needs-human.md)"
    return 0
  fi
  if [ -s "$outdir/evolution.md" ]; then
    log "SKIP issue $n - already reviewed ($outdir/evolution.md)"
    return 0
  fi
  local impl vals
  impl="$(runs_for_issue "$n" | grep -- '-implement-issue$' | tail -1 || true)"
  vals="$(runs_for_issue "$n" | grep -- '-validate-pr$' | tr '\n' ' ' || true)"
  if [ -z "$impl" ]; then
    log "SKIP issue $n - decided but no implement run on this machine (hand-driven lap?)"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN would evolve issue $n ($outcome; implement=$impl validate=${vals:-none})"
    return 0
  fi
  mkdir -p "$outdir"
  local cost; cost="$(lap_cost "$n")"
  render "factory/evolve-prompts/lap.md" "$outdir/prompt.md" \
    -e "s|{{issue_ref}}|gh:issue:$n|g" \
    -e "s|{{outcome}}|$outcome|g" \
    -e "s|{{cost}}|$cost|g" \
    -e "s|{{implement_run}}|$impl|g" \
    -e "s|{{validate_runs}}|${vals:-none recorded}|g" \
    -e "s|{{outdir}}|$outdir|g" \
    -e "s|{{recs}}|$RECS|g" || return 1
  log "EVOLVE issue $n ($outcome, lap cost \$$cost)"
  invoke "$outdir/prompt.md" "$outdir" "$outdir/evolution.md"
}

scan_window() {         # scan_window <days>
  local days="$1" stamp outdir outfile
  stamp="$(date -u +%Y-%m-%d)"
  outdir="$EVODIR/scan-$stamp"
  outfile="$outdir/scan.md"
  local run_list lap_count
  run_list="$(find "$RUNS_REAL" -maxdepth 1 -type d -name '2*' -mtime "-$days" | sort | tr '\n' ' ')"
  lap_count="$(issues_with_runs | wc -l | tr -d ' ')"
  if [ -z "$run_list" ]; then
    log "SCAN_SKIPPED no runs in the last $days days"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN would scan $days days: $(echo "$run_list" | wc -w | tr -d ' ') runs across $lap_count laps -> $outfile"
    return 0
  fi
  mkdir -p "$outdir"
  # The cost report goes in as a FILE the agent reads, not inline: it is multi-line
  # and sed substitution is line-shaped.
  python3 factory/cost.py report > "$outdir/cost-report.txt" 2>&1 || true
  render "factory/evolve-prompts/scan.md" "$outdir/prompt.md" \
    -e "s|{{window_days}}|$days|g" \
    -e "s|{{lap_count}}|$lap_count|g" \
    -e "s|{{run_list}}|$run_list|g" \
    -e "s|{{outfile}}|$outfile|g" \
    -e "s|{{recs}}|$RECS|g" \
    -e "s|{{cost_summary}}|$outdir/cost-report.txt|g" || return 1
  log "SCAN window=${days}d runs=$(echo "$run_list" | wc -w | tr -d ' ')"
  invoke "$outdir/prompt.md" "$outdir" "$outfile"
}

# --- dispatch ----------------------------------------------------------------
case "$MODE" in
  one)     evolve_one "$ARG" ;;
  window)  scan_window "$ARG" ;;
  catchup)
    FOUND=0
    for n in $(issues_with_runs); do
      FOUND=1
      evolve_one "$n" || log "EVOLVE_FAILED issue $n - continuing; re-run catch-up to retry"
    done
    # `|| true` because this test-and-log is the script's LAST statement: when laps WERE
    # found the test is false, and under `set -e` a false final command is the exit code.
    [ "$FOUND" -eq 0 ] && log "nothing to review - no runs recorded" || true
    ;;
esac
