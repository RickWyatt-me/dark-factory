#!/usr/bin/env bash
# The brain-seed post-merge step — dark-factory program Phase G, dossier 04 §3.
#
# The harness's gate-2 writer seeded the Construction OS Brain with what shipped and
# why; the factory carries that habit forward as a deterministic script. NO agent, on
# purpose: a lap record is a set of facts (sha, files, gate counts, cost), and Rick's
# standing rule for records is "derived from git, never from claims". Anything a model
# would add here is a claim.
#
#   bash factory/brain-seed.sh 17             seed the lap for issue 17
#   bash factory/brain-seed.sh --catch-up     seed every merged, un-seeded lap
#   ... --dry-run                             print the record, write nothing
#
# Seeds MERGED laps only. A parked lap is an escalation in .factory/needs-human.md,
# not shipped work; if it later merges, catch-up picks it up then.
#
# Writes to the BRAIN repo only (its post-commit hook auto-pushes). Brain state never
# rides a VOX commit and this script never touches the VOX working tree.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# shellcheck source=factory/config.sh
. "$ROOT/factory/config.sh"

BRAIN="${FACTORY_BRAIN_REPO:-$HOME/path/to/your-memory-repo}"
LAPS="$BRAIN/projects/vox/artifacts/factory/laps.md"
RUNS=".factory/runs"

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# Same backstop as evolve.sh: a seeding step that dies silently just stops seeding.
# Nothing to park — a missed record re-seeds on the next `--catch-up` — but the
# ending must say where it happened.
trap 'echo "[$(date -u +%FT%TZ)] SEED_FAULT line $LINENO exited $? running: $BASH_COMMAND - nothing after this ran; the next --catch-up retries"' ERR

[ -d "$BRAIN/.git" ] || { log "SEED_REFUSED: brain repo not found at $BRAIN"; exit 1; }

DRY_RUN=0
MODE=""
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --catch-up) MODE="catchup" ;;
    gh:issue:*) MODE="one"; ARG="${1#gh:issue:}" ;;
    [0-9]*)     MODE="one"; ARG="$1" ;;
    *) echo "usage: brain-seed.sh <issue-number> | --catch-up [--dry-run]"; exit 1 ;;
  esac
  shift
done
[ -z "$MODE" ] && { echo "usage: brain-seed.sh <issue-number> | --catch-up [--dry-run]"; exit 1; }

runs_for_issue() {
  grep -l "^id: gh:issue:$1\$" "$RUNS"/*/issue.md 2>/dev/null \
    | sed 's|/issue.md$||' | sort
}

lap_cost() {
  local jsons="" d
  for d in $(runs_for_issue "$1"); do
    [ -f "$d.json" ] && jsons="$jsons $d.json"
  done
  # shellcheck disable=SC2086
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

seed_one() {            # seed_one <issue-number>
  local n="$1"
  local sha
  sha="$(git log origin/develop -1 --format='%h' --grep="^Issue: gh:issue:$n\$" 2>/dev/null || true)"
  if [ -z "$sha" ]; then
    log "SKIP issue $n - no squash on origin/develop (not merged, or a hand-driven merge without the factory trailer)"
    return 0
  fi
  if [ -f "$LAPS" ] && grep -q "issue #$n · " "$LAPS"; then
    log "SKIP issue $n - already seeded"
    return 0
  fi

  local impl val title stat merged_on cost assume learning gate deployed
  impl="$(runs_for_issue "$n" | grep -- '-implement-issue$' | tail -1 || true)"
  val="$(runs_for_issue "$n" | grep -- '-validate-pr$' | tail -1 || true)"
  title="$(grep -m1 '^title: ' "${impl:-$val}/issue.md" 2>/dev/null | sed 's/^title: //' || true)"
  [ -z "$title" ] && title="$(git log -1 --format='%s' "$sha")"
  merged_on="$(git log -1 --format='%as' "$sha")"
  stat="$(git show --stat --format='' "$sha" | tail -1 | sed 's/^ *//')"
  cost="$(lap_cost "$n")"
  # Assumption blocks are `<claim>  | WHY: ...` lines; the continuation lines are
  # indented, so the count of WHY markers is the count of assumptions.
  assume="$( [ -n "$impl" ] && grep -c '| WHY:' "$impl/ASSUMPTIONS" 2>/dev/null || echo 0 )"
  # The Learning trailer wraps across lines, and the squash body carries only its FIRST
  # line (merge.sh folds trailers that way), so the run's own TRAILERS file is the
  # authoritative source and the squash is the fallback. Take everything from the key to
  # the next trailer key, folded to one line, so the seeded lesson is never cut off.
  extract_learning() {
    awk '/^Learning: /{f=1} f&&/^Affected: /{exit} f{print}' \
      | sed 's/^Learning: //' | tr '\n' ' ' | sed 's/  */ /g; s/ $//'
  }
  if [ -n "$impl" ] && [ -s "$impl/TRAILERS" ]; then
    learning="$(extract_learning < "$impl/TRAILERS")"
  else
    learning="$(git log -1 --format='%b' "$sha" | extract_learning)"
  fi
  gate="$( [ -n "$val" ] && grep -E '^(GATE_OK|EF_UNIT_PASSED|UNIT_PASSED|E2E_[A-Z]+_PASSED|HOLDOUT_PASSED)' "$val/gate.log" 2>/dev/null | tr '\n' ' ' || true )"
  # Deployed iff the deploy pointer has advanced to (or past) the squash. The pointer
  # is the same one deploy.sh keeps on origin/develop (Phase E).
  deployed="not yet deployed"
  local ptr; ptr="$(cat .factory/deploy/CURRENT 2>/dev/null || true)"
  if [ -n "$ptr" ] && git merge-base --is-ancestor "$sha" "$ptr" 2>/dev/null; then
    deployed="deployed (pointer covers it)"
  fi

  local record
  record="$(cat <<EOF

## $merged_on · issue #$n · $sha
- **What shipped:** $title
- **Change:** $stat
- **Gate:** ${gate:-no validate run recorded on this machine}
- **Deploy:** $deployed
- **Cost:** \$$cost agent spend · **Assumptions recorded:** $assume (VOX repo: .factory/assumptions/issue-$n.txt)
- **Learning:** ${learning:-none recorded}
EOF
)"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN would append to $LAPS:"
    echo "$record"
    return 0
  fi

  if [ ! -f "$LAPS" ]; then
    mkdir -p "$(dirname "$LAPS")"
    cat > "$LAPS" <<'EOF'
# VOX dark-factory lap ledger

One entry per merged factory lap, appended by `factory/brain-seed.sh` in the VOX repo
— every field derived from git and run artifacts, none from claims. Newest at the
bottom. The full run artifacts stay on the factory machine (`~/.vox-factory/runs/`);
process findings live in the VOX repo at `.factory/evolution/`.
EOF
  fi
  echo "$record" >> "$LAPS"
  git -C "$BRAIN" add "$LAPS"
  git -C "$BRAIN" commit -q -m "factory lap: VOX issue #$n merged as $sha" \
    || { log "SEED_FAILED issue $n - brain commit refused"; return 1; }
  log "SEEDED issue $n -> $LAPS (brain post-commit hook pushes)"
}

case "$MODE" in
  one) seed_one "$ARG" ;;
  catchup)
    FOUND=0
    for n in $({ grep -h '^id: gh:issue:' "$RUNS"/*/issue.md 2>/dev/null || true; } \
                 | sed 's/^id: gh:issue://' | sort -un); do
      FOUND=1
      seed_one "$n" || log "SEED_FAILED issue $n - continuing; re-run catch-up to retry"
    done
    # `|| true`: same shape as evolve.sh — a false final test must not become exit 1.
    [ "$FOUND" -eq 0 ] && log "nothing to seed - no runs recorded" || true
    ;;
esac
