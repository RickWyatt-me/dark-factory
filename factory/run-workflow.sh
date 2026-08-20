#!/usr/bin/env bash
# Run one workflow. The local runner.
#
#   bash factory/run-workflow.sh <workflow> <target>
#
# A target is `gh:issue:<n>` / `gh:pr:<n>` on the GitHub backend, or a path to
# `issues/<id>.md` / `.factory/prs/<id>.md` on the file backend. Which one you are on is
# decided by factory/state.py; this script reads it off the target and otherwise does not
# care, which is the property that let the move to GitHub be a change to two scripts
# rather than to every node.
#
# THIS FILE IS THE ORCHESTRATOR. There is no second definition of the pipeline.
#
# There used to be: factory/workflows/*.yaml described the same DAG for a workflow engine
# that was never wired up. Nothing executed them, so they drifted -- and what they drifted
# into was a `deny_paths: .factory/holdout/**` entry that made the holdout read-block look
# enforced when the only thing enforcing it was a sentence in a prompt. A stale spec that
# invents a safety property is worse than no spec. The YAMLs are deleted and the deny is
# now real, below, via --disallowedTools.

set -euo pipefail

WORKFLOW="${1:?workflow name}"
TARGET="${2:?target: gh:issue:<n>, gh:pr:<n>, or a path}"

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# See factory/state.py. Every `python3` in this script writes text that ends up on a pull
# request or an issue, and the default codepage on Windows mangles it silently.
export PYTHONIOENCODING=utf-8

# Everything project-specific lives in one file. If you are about to hardcode a path or
# a command anywhere below this line, put it in config.sh instead.
# shellcheck source=factory/config.sh
. "$ROOT/factory/config.sh"

# A FALLBACK, because escalate() calls this and an escalation must never be the thing
# that fails. `factory_notify` is defined in config.sh - but config.sh is the file you
# are told to edit, and an older or hand-customised copy will not have it. Observed:
# the runner escalated correctly, then died with `factory_notify: command not found`
# INSIDE the escalation, taking the message with it. A dependency added to the one path
# that runs when everything else has already gone wrong needs a floor under it.
command -v factory_notify >/dev/null 2>&1 || factory_notify() {
  echo "NOT NOTIFIED - factory/config.sh defines no factory_notify (old copy?); recorded in .factory/needs-human.md"
}

AGENT="$FACTORY_AGENT"
MODEL_PREMIUM="$FACTORY_MODEL_PREMIUM"
MODEL_CHEAP="$FACTORY_MODEL_CHEAP"
# Sized from measured laps. The first genuinely
# multi-part issue exhausted 60 turns and escalated having written nothing, AFTER the
# premium plan node had already been paid for. A cap that is too low does not save
# money, it throws away the expensive half of the lap. This is a COST guard and not a
# safety gate: nothing downstream trusts it, and the gate is identical either side of it.
MAX_BUDGET="$FACTORY_MAX_BUDGET_USD"

# --- which backend, read off the target -------------------------------------
# Not from an env var. A workflow handed `gh:pr:4` is working on a pull request whatever
# the environment says, and a mismatch between the two is the kind of thing that only
# shows up as a merge into the wrong place.
case "$TARGET" in
  gh:*) GH=1 ;;
  *)    GH=0 ;;
esac

# THE STOP BUTTON, honoured on hand-runs too. The dispatcher checks it every tick and
# ci.py checks it before any rung; a workflow started by hand while the line is stopped
# should not be the one path that ignores it.
if [ -f "${FACTORY_STOP_FILE:-.factory/STOP}" ]; then
  echo "STOPPED: ${FACTORY_STOP_FILE:-.factory/STOP} present. No workflow runs while the line is stopped; remove it to resume."
  exit 0
fi

# The base ref: DEVELOP (program decision D2 -- main stays Rick's, forever). On GitHub
# the base is what the REMOTE says it is, not what this checkout last fetched -- a stale
# local branch computes the merge base against a commit that is no longer the tip and
# the guard's three-dot diff quietly widens. On the file backend (the machinery fixture,
# which has no develop) the runner falls back to main, that fixture's base.
BASE_BRANCH="${FACTORY_BASE_BRANCH:-develop}"
if [ "$GH" -eq 1 ]; then
  git fetch --quiet origin "$BASE_BRANCH" || { echo "cannot fetch origin/$BASE_BRANCH; refusing to run against a stale base"; exit 1; }
  BASE="origin/$BASE_BRANCH"
else
  if git rev-parse --verify --quiet "$BASE_BRANCH" >/dev/null; then
    BASE="$BASE_BRANCH"
  else
    BASE="main"
  fi
fi

RUN="$(date -u +%Y%m%dT%H%M%S)-$WORKFLOW"
# ABSOLUTE, deliberately. Every node cd's into its worktree before running, so a relative
# run directory resolves inside the worktree -- where it does not exist. The first real
# headless lap failed exactly this way: every node's prompt render, stdout capture and
# stderr capture went to a path that was not there, all three nodes "failed", and the
# workflow escalated. It failed closed, which is the right outcome, but the cause was
# eight characters of path.
RUNDIR="$ROOT/.factory/runs/$RUN"
# the prompts already write ".factory/runs/{{run}}/...", so substituting a relative
# prefix here rendered ".factory/runs/.factory/runs/<id>/priming.md". The plan node then
# could not read its priming, produced its plan in the reply instead of writing the file,
# and the implement node correctly refused to invent one and escalated.
mkdir -p "$RUNDIR/nodes"

# RESOLVED, because `.factory/runs` is a symlink into ~/.vox-factory since the iCloud
# shield (Phase D lap 1) and the agent's acceptEdits path-scoping follows symlinks: a
# node handed `--add-dir "$ROOT"` alone is silently denied every Write into its own run
# dir (lap 2, finding A — prime's priming.md was never written, twice). The permission
# fence has to name the REAL path.
RUNDIR_REAL="$(cd "$RUNDIR" 2>/dev/null && pwd -P || echo "$RUNDIR")"

export FACTORY_RUN_ID="$RUN"

# Token instrumentation is on from the first run, not added later (FACTORY_RULES.md 8) --
# so it has to survive the run failing, which is when you most want to know what it cost.
# The teardown step in the YAML says `always: true`; bash does not honour a YAML comment,
# and the final `cost.py record` line was unreachable on every escalation and every
# blocked gate. A trap is what `always` actually means here.
trap 'python3 factory/cost.py record "$RUN" >/dev/null 2>&1 || true' EXIT

log() { echo "[$(date -u +%FT%TZ)] [$WORKFLOW/$TARGET] $*"; }

state()   { python3 factory/state.py "$@"; }
# `|| true`, and it is the difference between an escalation and a silent death.
#
# Under `set -euo pipefail`, a `grep` that matches nothing returns 1, the pipeline
# returns 1, and `set -e` kills the script THERE - before the `[ -n "$BRANCH" ] ||
# escalate` on the next line ever runs. So a PR record missing a field did not escalate,
# did not reach needs-human, did not notify: the workflow exited 1 having printed one
# line, which is indistinguishable from a crash and looks like nothing at all in a log
# nobody is watching.
#
# The check that handles the missing field was written correctly and was unreachable.
# Same shape as a red gate that could never reach the fix node: the error path existed,
# and the language got there first.
read_fm() { python3 factory/state.py get "$2" 2>/dev/null | grep "^$1=" | head -1 | cut -d= -f2- || true; }
note()    { python3 factory/state.py comment "$1"; }   # body on stdin

escalate() {            # escalate <reason>
  log "ESCALATE: $*"
  python3 factory/state.py set "$TARGET" state=needs-human || true
  echo "- $(date -u +%FT%TZ)  $TARGET  ($WORKFLOW)  $*" >> .factory/needs-human.md

  # AND THE ISSUE BEHIND IT. `gate.sh`'s fail() has done this for a while, with a comment
  # explaining why; the other two escalation routes never learned it. So a PR that hit the
  # fix cap went to needs-human while ITS ISSUE stayed `in-progress` - unlabelled, invisible
  # as a problem, and `state.py next` cheerfully moved on to the next issue. The factory
  # carries on while an escalated piece of work sits in a state that means "being worked on"
  # and nothing is. FACTORY_RULES.md 7 says escalation stops activity on that issue AND its
  # PR; one of the three routes implemented it.
  ESC_ISSUE="$(python3 factory/state.py get "$TARGET" 2>/dev/null | grep '^issue=' | head -1 | cut -d= -f2- || true)"
  if [ -n "${ESC_ISSUE:-}" ] && [ "$ESC_ISSUE" != "$TARGET" ]; then
    python3 factory/state.py set "$ESC_ISSUE" state=needs-human >/dev/null 2>&1 || true
    echo "- $(date -u +%FT%TZ)  $ESC_ISSUE  ($WORKFLOW)  its PR $TARGET escalated: $*" >> .factory/needs-human.md
  fi

  # THE ONE THING THAT REACHES A HUMAN. Everything else this factory writes waits to be
  # found. `needs-human` is the only state a human must act on, so it is the only state
  # allowed to interrupt one - and if it cannot, "unattended" quietly means "unmonitored".
  #
  # Never fatal: an escalation that fails because a webhook is down must still be an
  # escalation. The file write above already happened.
  log "$(factory_notify "$TARGET" "($WORKFLOW) $*")"
  # The run's own directory keeps a copy (evolution rec, lap #8): an escalated run
  # used to leave the LEAST evidence in its own run dir, right when a trail matters
  # most — reconstructing PR #9's tripwire park meant grepping feed.log by timestamp.
  [ -n "${RUNDIR:-}" ] && echo "$*" > "$RUNDIR/ESCALATION" 2>/dev/null || true
  if [ "$GH" -eq 1 ]; then
    # Assembled in one process, like every other human-facing write. FACTORY_RULES.md 10.1.
    python3 factory/state.py escalate-note "$TARGET" "$WORKFLOW" "$*" || true
  fi
  exit 3
}

# THE BACKSTOP FOR THE ENTIRE CLASS OF FAILURE DESCRIBED AT read_fm ABOVE.
#
# That comment diagnoses the shape exactly: under `set -euo pipefail` an unguarded
# command returning non-zero kills the script BEFORE the escalate on the next line, and
# the result is indistinguishable from nothing having happened. It was found and fixed
# four separate times by accident -- read_fm, fix-pr, validate-pr, gate.sh -- each time as
# an instance. Auditing every `set -e` script for the shape found three more still live,
# including one on the protected-path guard, so fixing instances was never going to
# converge. Two facts made every one of them invisible rather than merely fatal:
#
#   1. nothing in this script trapped ERR, so a death printed nothing about itself, and
#   2. the orchestrator dispatches this runner into a BACKGROUND subshell and never reads
#      its exit status, so nothing downstream noticed either.
#
# Worked example, the one that was live: an issue with no `title:` line made
#   TITLE="$(grep -m1 '^title:' "$ISSUE_FILE" | ...)"
# return 1, which killed the run at that line. The issue was never moved to `in-progress`
# (that happens further down), so `state.py next` handed the SAME issue back on the next
# tick, and the factory re-dispatched a run that could only die, every tick, forever --
# logging a cheerful DISPATCH line each time. Busy, progressing at zero, notifying nobody.
#
# THIS TRAP CANNOT CHANGE CONTROL FLOW. `set -e` already terminates the script at exactly
# these points; the trap only makes the termination say why and route through escalate(),
# which parks the work and notifies. It converts silent death into a loud stop.
#
# Deliberately NOT `set -E` (errtrace): without it the trap fires for top-level commands
# only, which is where every instance found lives. With it, ERR also fires inside command
# substitutions and subshells, where an escalate() would exit the SUBSHELL and leave the
# parent running -- a duplicate, half-applied escalation that is worse than the disease.
on_unguarded_error() {  # on_unguarded_error <rc> <line> <command>
  trap - ERR            # never recurse: escalate() runs commands of its own
  log "RUNNER_FAULT line $2 exited $1: $3"
  escalate "the runner died at line $2 (exit $1) running: $3 -- this is an unguarded command failure, not a decision about the work"
}
trap 'on_unguarded_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# --- identifiers -------------------------------------------------------------
# ISSUE_NUM keys the worktree path. Windows MAX_PATH is 260 characters and this repo
# already sits deep under a temp directory; the validator's path is 9 characters longer
# than the implementer's ("validate-"), and that alone pushed a vendored skill file over
# the limit. `git worktree add` then failed with "Filename too long" and the validator
# escalated on a path length. core.longpaths is also set on the repo; this is the belt to
# that pair of braces.
if [ "$GH" -eq 1 ]; then
  ISSUE_NUM="${TARGET##*:}"
  ISSUE_ID="issue-$ISSUE_NUM"
else
  ISSUE_ID="$(basename "$TARGET" .md)"
  ISSUE_NUM="$(printf '%s' "$ISSUE_ID" | grep -oE '^[0-9]+' || printf '%s' "$ISSUE_ID")"
fi

# --- the issue, as a file a node can read ------------------------------------
# THE JOIN FACTORY_RULES.md 11 HAD NO ROW FOR. Every node prompt takes `{{issue}}` and
# opens it. An issue that lives behind an API cannot be opened, so it is rendered here to
# one path, ONCE, before any node runs. Rendering it once is also what keeps every node
# judging the same text: re-fetching per node would let a mid-run edit change what the
# judge thinks was asked for.
materialise() {         # materialise <issue-target>
  ISSUE_FILE="$RUNDIR/issue.md"
  python3 factory/state.py body "$1" > "$ISSUE_FILE" \
    || { echo "could not read $1"; return 1; }
  log "ISSUE_MATERIALISED $1 -> $ISSUE_FILE ($(wc -l < "$ISSUE_FILE") lines)"
}

# --- one node ----------------------------------------------------------------
# Each node gets a FRESH agent session. Not a performance choice: a node that inherits
# the previous node's context inherits the previous node's reasoning, and the whole
# holdout argument (FACTORY_RULES.md 9) rests on some nodes not having seen it.
#
# HOLDOUT_DENY is passed to every node. The builder must not READ the assertions it is
# judged against, and until now that was a sentence in a prompt: the deny list lived in
# factory/workflows/*.yaml, which nothing executed. guard.py blocked holdout WRITES on
# the committed diff, so the wall was real in one direction and imaginary in the other.
# A node with Read+Glob+Grep could open .factory/holdout/e2e.py and write code aimed at
# the exact assertions. --disallowedTools is enforced by the agent, not by the prompt.
HOLDOUT_DENY="Read($FACTORY_HOLDOUT_DIR/**) Glob($FACTORY_HOLDOUT_DIR/**) Grep($FACTORY_HOLDOUT_DIR/**)"

node() {                # node <name> <model> <prompt-file> <allowed-tools>
  local name="$1" model="$2" prompt="$3" tools="$4"
  log "NODE $name (model=$model)"

  mkdir -p "$RUNDIR/nodes"
  local rendered="$RUNDIR/nodes/$name.prompt.md"
  if ! sed -e "s|{{issue}}|${ISSUE_FILE:-$TARGET}|g" \
           -e "s|{{issue_id}}|$ISSUE_ID|g" \
           -e "s|{{issue_ref}}|$TARGET|g" \
           -e "s|{{run}}|$RUN|g" \
           -e "s|{{branch}}|${BRANCH:-}|g" \
           -e "s|{{base}}|$BASE|g" \
           -e "s|{{prfile}}|${PRFILE:-}|g" \
           -e "s|{{attempts}}|${ATTEMPTS:-0}|g" \
           -e "s|{{rundir}}|$RUNDIR_REAL|g" \
           -e "s|{{findings}}|${FINDINGS:-}|g" \
           -e "s|{{gatelog}}|${FINDINGS_LOG:-}|g" \
           -e "s|{{quick}}|$FACTORY_VALIDATE_QUICK|g" \
           "$prompt" > "$rendered"; then
    log "NODE_FAILED $name -- could not render the prompt to $rendered"
    return 1
  fi

  # AN UNRENDERED PLACEHOLDER IS A PROMPT THAT LIES, and it fails silently in the worst
  # possible way: the node is handed a path like `.factory/runs/{{prev_run}}/verdict.json`,
  # opens nothing, and carries on. It does not crash and it does not refuse - it just works
  # from no evidence, and produces something confident and unfounded.
  #
  # Found on the fix node, which asked for the validator's findings through a placeholder
  # this renderer never substituted. Every fix attempt would have been a guess at what the
  # validator objected to.
  #
  # Fatal, not a warning: a node reasoning from a file that does not exist is worse than a
  # node that did not run.
  if grep -qE '\{\{[a-z_]+\}\}' "$rendered"; then
    log "NODE_FAILED $name -- the rendered prompt still contains $(grep -ohE '\{\{[a-z_]+\}\}' "$rendered" | sort -u | tr '\n' ' ')- the runner does not substitute that. A node cannot read a path that was never filled in."
    return 1
  fi

  # shellcheck disable=SC2086 -- HOLDOUT_DENY is a deliberate word list, not one argument.
  if ! "$AGENT" -p "$(cat "$rendered")" \
        --model "$model" \
        --allowedTools "$tools" \
        --disallowedTools $HOLDOUT_DENY \
        --permission-mode acceptEdits \
        --add-dir "$ROOT" --add-dir "$RUNDIR_REAL" \
        --max-budget-usd "$MAX_BUDGET" \
        --output-format json \
        > "$RUNDIR/nodes/$name.json" 2> "$RUNDIR/nodes/$name.err"; then
    # WHY it failed, not just that it did. The agent records the reason in its own JSON,
    # and running out of turns is a BUDGET the operator set -- a completely different thing
    # from a node that refused, crashed, or was denied a tool it needed. All three used to
    # escalate as "a build node failed", which sends whoever reads it at 3am looking for a
    # bug that is not there. Naming the cause is most of what an escalation is worth.
    #
    # Written to a FILE, not a variable: nodes run inside a subshell, so a variable set
    # here never reaches the escalate() that reports it.
    python3 factory/node_failure.py "$RUNDIR/nodes/$name.json" "$name" "$MAX_BUDGET" \
      > "$RUNDIR/NODE_FAILURE" 2>/dev/null || echo "$name: reason unavailable" > "$RUNDIR/NODE_FAILURE"
    log "NODE_FAILED $(cat "$RUNDIR/NODE_FAILURE")"
    sed 's/^/    /' "$RUNDIR/nodes/$name.err" | tail -20
    return 1
  fi

  # A node can be DENIED A TOOL and still exit 0. The implement node did exactly that: it
  # asked twice to run a `python3 -c` its allowlist did not cover, was refused, replied "the
  # command needs approval from you to run", and exited SUCCESSFULLY having changed
  # nothing. The workflow reported "produced no file changes at all" -- true, a good
  # backstop, and the wrong cause.
  #
  # Recorded and printed, but NOT fatal, and that distinction was itself learned here: the
  # plan node is denied tools on almost every run, asks anyway, works around it and writes
  # a good plan. A denial says a node wanted something it could not have. Whether that
  # mattered is decided by whether the node produced anything, which is checked downstream.
  python3 factory/node_failure.py --denials-only "$RUNDIR/nodes/$name.json" "$name" \
    > "$RUNDIR/nodes/$name.denials" 2>/dev/null || true
  if [ -s "$RUNDIR/nodes/$name.denials" ]; then
    log "NODE_DENIED $(head -c 400 "$RUNDIR/nodes/$name.denials")"
    cat "$RUNDIR/nodes/$name.denials" >> "$RUNDIR/DENIALS"
  fi
  log "NODE_OK $name"
}

# Make a worktree path usable, whatever state a previous run left it in.
#
# `git worktree remove --force` can drop git's record and still leave the directory on
# disk -- routine on Windows, where an agent process may still hold a handle when the
# teardown runs. The next run then fails at `worktree add` and escalates, and the factory
# is wedged on a directory rather than on anything real. An unattended system has to be
# able to start from the mess its previous self left.
prepare_worktree_path() {   # prepare_worktree_path <path>
  local wt="$1"
  git worktree remove "$wt" --force >/dev/null 2>&1 || true
  git worktree prune >/dev/null 2>&1 || true
  [ -e "$wt" ] && rm -rf "$wt"
  return 0
}

# The gate cannot run from a bare worktree: node_modules and the gitignored env inputs
# never arrive with a checkout, so `npm run lint` and the serve-env assembly would fail
# on a tree that is otherwise perfectly healthy. Symlink each configured item from the
# root checkout; every one is gitignored, so a worktree `git add -A` cannot sweep one up.
provision_worktree() {      # provision_worktree <path>
  local wt="$1" item
  for item in $FACTORY_WORKTREE_LINKS; do
    [ -e "$ROOT/$item" ] || continue
    [ -e "$wt/$item" ] && continue
    mkdir -p "$wt/$(dirname "$item")" 2>/dev/null || true
    ln -s "$ROOT/$item" "$wt/$item" 2>/dev/null || true
  done
  return 0
}

# --- the migration-number race (issue #64) -----------------------------------
#
# Two laps in flight can both mint the same 00NNN: each computes "highest in the
# folder + 1" from its own branch-time snapshot of the base. Observed 2026-08-19/20:
# PR #43 merged 00169_weekly_report_tenancy_rekey while PR #38 sat parked carrying
# 00169_reprocess_failed_pipeline_run, and #38's rebase then died on a MIGRATIONS.md
# conflict this runner refused to resolve. A human renumbered #38's file to 00170 by
# hand (branch commit 6d0f402). These two helpers make the validate node do exactly
# that mechanical fix, and nothing beyond it.
#
# Renumber-on-rebase over a reservation counter, deliberately: migrations are minted
# by HUMAN sessions at least as often as by laps, and a human following the skill
# ("next = highest in folder + 1") would never consult a factory lock file — so a
# counter only coordinates laps with each other and leaves the likelier collision
# class unfixed, while also becoming a second source of truth beside the folder the
# skill names as the only one. The collision is instead settled at the one point
# where ordering becomes real (the pre-validation rebase), and BEFORE anything is
# judged — everything downstream judges the renumbered tree, so nothing merges in a
# form no judge saw. Any ambiguity escalates; the factory does not guess.

# A rebase stopped ONLY on supabase/migrations/MIGRATIONS.md is not a content
# conflict — the index is a generated file ("do not edit by hand"), so the resolution
# is to regenerate it from the files actually in the tree and continue. Any other
# unmerged path is a real conflict and stays a human problem: return 1 with the
# rebase state intact so the caller's abort-and-escalate path reads it.
settle_index_conflicts() {   # settle_index_conflicts <worktree>  -> 0 rebase completed
  local wt="$1" gd tries=0 unmerged
  gd="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  while [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; do
    tries=$((tries+1)); [ "$tries" -gt 20 ] && return 1
    unmerged="$(git -C "$wt" diff --name-only --diff-filter=U)"
    [ "$unmerged" = "supabase/migrations/MIGRATIONS.md" ] || return 1
    # Exit 1 here means duplicate numbers — expected mid-race; the file is still
    # written and the post-rebase renumber below settles the duplicate itself.
    ( cd "$wt" && node scripts/gen-migrations-index.mjs ) || true
    # Never stage a file that still carries conflict markers: if the generator did
    # not run (node missing, script absent on an old branch), adding the conflicted
    # index would commit the markers as content.
    grep -q '^<<<<<<<' "$wt/supabase/migrations/MIGRATIONS.md" && return 1
    git -C "$wt" add supabase/migrations/MIGRATIONS.md || return 1
    # --skip is the fallback for a commit the resolution emptied (a commit that only
    # touched the index). GIT_EDITOR=true: no editor exists in a headless run.
    GIT_EDITOR=true git -C "$wt" rebase --continue \
      || GIT_EDITOR=true git -C "$wt" rebase --skip \
      || true
  done
  return 0
}

# After a completed rebase, a migration the branch added whose 00NNN is already taken
# on the base (under a DIFFERENT name — same name never conflicts, it deduplicates)
# gets the next free number: git mv + the header line's number token + a regenerated
# index, committed on the branch. That is byte-for-byte the human fix on PR #38, and
# nothing else: content is untouched, and the guard/gate/judge all run after this.
# Returns 1 — the caller escalates — when the duplicate cannot be settled without a
# choice: the generator is red for a reason other than duplicates, a duplicate pair
# is not exactly one base file + one branch file, or any mechanical step fails.
renumber_duplicate_migrations() {   # renumber_duplicate_migrations <worktree>
  local wt="$1" base_files dupes num keep branch_file f bn next newfile
  ( cd "$wt" && node scripts/gen-migrations-index.mjs ) >/dev/null 2>&1 && return 0
  base_files="$(git ls-tree -r --name-only "$BASE" -- supabase/migrations/ | sed 's|.*/||')"
  dupes="$(ls "$wt/supabase/migrations" | grep -E '^[0-9]{5}_.*\.sql$' | cut -c1-5 | sort | uniq -d)"
  [ -n "$dupes" ] || return 1
  for num in $dupes; do
    keep=0; branch_file=""
    for f in "$wt"/supabase/migrations/"${num}"_*.sql; do
      bn="$(basename "$f")"
      if printf '%s\n' "$base_files" | grep -qxF "$bn"; then keep=$((keep+1)); else branch_file="$bn"; fi
    done
    [ -n "$branch_file" ] && [ "$keep" -eq 1 ] || return 1
    next="$(ls "$wt/supabase/migrations" | grep -E '^[0-9]{5}_' | cut -c1-5 | sort -n | tail -1)"
    next="$(printf '%05d' $((10#$next + 1)))"
    newfile="${next}_$(printf '%s' "$branch_file" | cut -c7-)"
    git -C "$wt" mv "supabase/migrations/$branch_file" "supabase/migrations/$newfile" || return 1
    # Line 1 is the skill-mandated header; only its number token changes. python3, not
    # sed -i (BSD/GNU -i disagree), and it refuses a line 1 that is not the header.
    python3 - "$wt/supabase/migrations/$newfile" "$num" "$next" <<'PY' || return 1
import io, sys
p, old, new = sys.argv[1:4]
lines = io.open(p, encoding='utf-8').read().split('\n')
if not lines or not lines[0].startswith('-- %s ' % old):
    raise SystemExit('line 1 is not the %s header' % old)
lines[0] = '-- ' + new + lines[0][len('-- ' + old):]
io.open(p, 'w', encoding='utf-8', newline='\n').write('\n'.join(lines))
PY
    echo "$branch_file -> $newfile" >> "$RUNDIR/RENUMBERED"
    log "MIGRATION_RENUMBERED $branch_file -> $newfile — $num is already taken on $BASE under a different name (migration-number race, issue #64)"
  done
  # Must be green now — a still-red generator means the settle above was not enough.
  ( cd "$wt" && node scripts/gen-migrations-index.mjs ) >/dev/null 2>&1 || return 1
  git -C "$wt" add supabase/migrations/ || return 1
  git -C "$wt" commit -q \
    -m "chore(factory): renumber migration on rebase - number already taken on base (#$ISSUE_NUM)" \
    -m "Mechanical rewrite by the validate node, BEFORE judging: $(paste -sd ', ' "$RUNDIR/RENUMBERED" 2>/dev/null || echo 'see RENUMBERED') — rename + header number + regenerated index only; migration content untouched. Everything downstream (guard, gate, judge) runs against this tree. Issue #64.

Epic: factory
Story: issue-$ISSUE_NUM
Type: fix
Learning: none recorded
Affected: supabase/migrations" || return 1
  return 0
}

# --- the per-target lock, for runs started BY HAND ---------------------------
#
# THE HOLE THIS CLOSES. The lock lived entirely in orchestrator.sh, so it protected two
# dispatchers from each other and nothing else. But Phase 7 of the skill tells you to
# "run the walking skeleton by hand: one real issue, all the way to a PR you merge
# yourself" - and a hand-run invokes THIS script directly, taking no lock at all.
#
# So the documented human workflow bypassed the one mechanism that stops two runs
# operating on the same target. Observed: a cron tick dispatched `triage issues/0011`
# seventeen seconds before a hand-driven run of the same workflow on the same repo. The
# second judges a tree the first is still writing, which is exactly what the lock exists
# to prevent.
#
# When the orchestrator dispatched us it exports FACTORY_LOCK_HELD and we trust it - it
# already holds the lock and releases it on its own trap. Otherwise we take one, with the
# same key and the same atomic O_EXCL create, and release it on exit.
if [ -z "${FACTORY_LOCK_HELD:-}" ]; then
  SELF_LOCKDIR=".factory/locks-runtime"
  mkdir -p "$SELF_LOCKDIR"
  SELF_KEY="$(echo "${WORKFLOW}-${TARGET}" | tr '/.:' '---')"
  SELF_LOCK="$SELF_LOCKDIR/$SELF_KEY.lock"
  set -C
  if ! echo "$$ $(date -u +%FT%TZ) hand-run" > "$SELF_LOCK" 2>/dev/null; then
    set +C
    echo "REFUSED: $WORKFLOW $TARGET is already in flight ($SELF_LOCK)."
    echo "  Another run - a cron tick, or another terminal - holds this target. Two runs on"
    echo "  one target means the second judges a tree the first is still editing."
    echo "  Wait for it, or remove the lock if you know its process is gone."
    exit 4
  fi
  set +C
  # ONE combined trap: bash keeps only the last trap per signal, and this line used to
  # silently replace the cost-record trap armed at the top of the script — cost.py
  # recorded nothing on any hand-run lap (Phase D lap 1, patch 2).
  trap 'python3 factory/cost.py record "$RUN" >/dev/null 2>&1 || true; rm -f "$SELF_LOCK"' EXIT INT TERM
  log "LOCK_TAKEN $SELF_LOCK (hand-run)"
fi

# --- pre-flight, before anything that could commit ---------------------------
# FACTORY_RULES.md 5.2. It mattered when this repo was local-only and it matters more
# now: a `git add -A` that sweeps up a token no longer publishes it to a disk, it
# publishes it to a remote, and the remote keeps it after the delete.
for f in $FACTORY_SECRET_FILES; do
  git check-ignore -q "$f" || escalate "PREFLIGHT: $f is not gitignored; a git add -A would publish it"
done
log "PREFLIGHT_OK backend=$([ "$GH" -eq 1 ] && echo github || echo files) base=$BASE"

case "$WORKFLOW" in

  implement-issue)
    materialise "$TARGET" || escalate "could not read the issue"
    # `|| true` for the read_fm reason, and this one was LIVE. An issue file with no
    # `title:` line made this grep return 1 and killed the run right here -- before the
    # issue was moved to `in-progress`, so the dispatcher handed the same issue back every
    # tick and re-ran a workflow that could only die. Nothing else in this system requires
    # a title: state.py prints `i.get('title', i.get('issue',''))` and factory_doctor does
    # not check for one, so an untitled issue is a supported input everywhere except the
    # one line that read it. On the GitHub backend `state.py body` always emits a title,
    # which is why this only ever bit the file backend -- the one a local factory uses.
    TITLE="$(grep -m1 '^title:' "$ISSUE_FILE" | cut -d: -f2- | sed 's/^ *//' || true)"
    [ -n "$TITLE" ] || TITLE="$(basename "$ISSUE_FILE" .md)"

    if [ "$GH" -eq 1 ]; then
      BRANCH="factory/issue-$ISSUE_NUM"
      PRFILE="$RUNDIR/pr.md"
    else
      BRANCH="factory/$ISSUE_ID"
      PRFILE=".factory/prs/$ISSUE_ID.md"
    fi
    WT=".worktrees/i$ISSUE_NUM"

    prepare_worktree_path "$WT"
    git rev-parse --verify --quiet "$BRANCH" >/dev/null && git branch -D "$BRANCH" >/dev/null 2>&1 || true
    git worktree add "$WT" -b "$BRANCH" "$BASE" >/dev/null 2>&1 || escalate "could not create worktree $WT"
    provision_worktree "$WT"
    python3 factory/state.py set "$TARGET" state=in-progress || escalate "illegal state transition"

    (
      cd "$WT"
      # `git show` added 2026-08-20 (issue #60, 5th denial sighting): prime kept
      # reaching for read-only `git show` during its targeted read and burning
      # retries on denials — same class d9eeca9 fixed for the judge and review
      # nodes. `git fetch` stays out (mutates refs).
      node prime     "$MODEL_CHEAP"   "$ROOT/factory/prompts/prime.md" \
           "Read,Glob,Grep,Bash(git log:*),Bash(git show:*),Bash(git ls-files:*),Bash(git status)"
      # NODE_OK only means the agent exited 0 — denials are non-fatal by design, so a
      # prime that was refused its Write still "succeeds" with no priming on disk (lap 2,
      # finding B: it happened twice and nothing said so). Loud, not fatal: the opus plan
      # node proved it can re-derive a priming from a cold read, and killing the lap here
      # would have turned both of lap 2's self-healed runs into escalations.
      [ -s "$RUNDIR/priming.md" ] \
        || log "PRIMING_MISSING prime exited OK but wrote no priming.md — plan runs from a cold read"
      node plan      "$MODEL_PREMIUM" "$ROOT/factory/prompts/plan.md" \
           "Read,Glob,Grep,Write"
      # `Bash(python3 -c:*)` added 2026-08-10. The node could previously execute exactly one
      # command -- the quick gate -- so it could not measure anything, and it was handed an
      # issue that is entirely about counting things on a screen. It asked to run a
      # one-liner, was refused, and stopped to ask a human who was not there.
      #
      # This does weaken the `--quick`-only leash, and the leash was never what enforced
      # the property anyway. What stops a builder tuning against the gate is that the
      # VALIDATOR re-runs everything independently, that 22 mutations must all be caught,
      # and that the ratchet refuses a quieter harness. Tool scoping was a nudge, and
      # keeping a nudge that costs a whole lap is not a trade worth making.
      node implement "$MODEL_CHEAP"   "$ROOT/factory/prompts/implement.md" \
           "Read,Glob,Grep,Edit,Write,Bash(python3 -c:*),Bash(git diff:*),Bash(git status:*),Bash($FACTORY_VALIDATE_QUICK)"
    ) || { git worktree remove "$WT" --force >/dev/null 2>&1 || true
           escalate "$(cat "$RUNDIR/NODE_FAILURE" 2>/dev/null || echo 'a build node failed, reason not recorded')"; }

    # An explicit escalation file beats a silent no-op. The plan node stops only for the
    # short list in prompts/plan.md; when it does, it says so here, and this is the only
    # path that turns that into a state change.
    if [ -s "$RUNDIR/ESCALATE" ]; then
      git worktree remove "$WT" --force >/dev/null 2>&1 || true
      escalate "$(head -c 800 "$RUNDIR/ESCALATE")"
    fi

    # ASSUMPTIONS ARE NOT ESCALATIONS. They ride through the build and hold the MERGE.
    #
    # THE FAILURE THIS REPLACES. The plan node used to be told to stop for "an answer to
    # any other MISSION open question", so one unmade product decision blocked every issue
    # downstream of it. Four issues filed against one game produced four escalations, zero
    # PRs, and the SAME question asked four times - because an open question in a PRD was
    # being read as "you may not propose" when the author meant "I have not decided". The
    # more honest the PRD, the less the factory could do.
    #
    # Now the node decides, records what it assumed, and builds. The assumption travels
    # into the PR record and `gate.sh` refuses the AUTO-merge on it - the same mechanism
    # that already holds a merge on an uncalibrated threshold. So the work is built,
    # validated, and waiting with the reasoning at the top, and the human answers a
    # concrete question about a running thing rather than an abstract one in the dark.
    if [ -s "$RUNDIR/ASSUMPTIONS" ]; then
      mkdir -p .factory/assumptions
      cp "$RUNDIR/ASSUMPTIONS" ".factory/assumptions/$ISSUE_ID.txt" 2>/dev/null || true
      log "ASSUMPTIONS_RECORDED $(grep -c . "$RUNDIR/ASSUMPTIONS" 2>/dev/null || echo 0) - the build continues; the MERGE will be held"
      sed 's/^/    /' "$RUNDIR/ASSUMPTIONS" | head -20
    fi

    # A follow-up the node could not build, from an issue it mostly could. Recorded rather
    # than lost: partially building an issue is right, silently dropping the rest is not.
    if [ -s "$RUNDIR/FOLLOWUP" ]; then
      mkdir -p .factory/followups
      cp "$RUNDIR/FOLLOWUP" ".factory/followups/$ISSUE_ID.md" 2>/dev/null || true
      log "FOLLOWUP_RECORDED .factory/followups/$ISSUE_ID.md - part of this issue was deliberately left"
    fi

    # COMMIT. Without this the whole lap is theatre: the implement node edits files in
    # the worktree, nothing records them, and `git worktree remove --force` discards the
    # work. The first real headless lap did exactly that -- every node reported OK, the
    # guard correctly saw 2 files and 30 lines, and the branch ended up empty. Driving the
    # lap by hand had hidden it, because a human commits without being told to.
    if [ -z "$(git -C "$WT" status --porcelain)" ]; then
      git worktree remove "$WT" --force >/dev/null 2>&1 || true
      # Denials are the usual CAUSE of an empty diff, so they are reported alongside it
      # rather than left in a log for somebody to correlate an hour later.
      DENIED=""
      [ -s "$RUNDIR/DENIALS" ] && DENIED=" It was denied tools: $(head -c 500 "$RUNDIR/DENIALS")"
      escalate "the implement node produced no file changes at all -- nothing to validate.$DENIED"
    fi
    git -C "$WT" add -A
    # The BMAD trailers ride into the factory's commit step (FACTORY_RULES.md 2). The
    # implement node writes {{rundir}}/TRAILERS; a lap never dies on trailer prose, so a
    # missing or malformed file gets a deterministic fallback the reviewer can see.
    TRAILER_BLOCK=""
    if [ -s "$RUNDIR/TRAILERS" ] \
       && [ "$(grep -cE '^(Epic|Story|Type|Learning|Affected):' "$RUNDIR/TRAILERS" 2>/dev/null || true)" -ge 5 ]; then
      TRAILER_BLOCK="$(grep -E '^(Epic|Story|Type|Learning|Affected):' "$RUNDIR/TRAILERS" || true)"
    else
      # Loudly, since lap #8: the fallback fired silently and the only trace was a
      # generic-looking trailer block on the squash (evolution rec).
      log "TRAILERS_FALLBACK_USED - $RUNDIR/TRAILERS missing or malformed; using generic trailers"
      AFFECTED_TOP="$(git -C "$WT" diff --cached --name-only 2>/dev/null | cut -d/ -f1-2 | sort -u | paste -sd ',' - | head -c 120 || true)"
      TRAILER_BLOCK="Epic: factory
Story: issue-$ISSUE_NUM
Type: factory
Learning: none recorded
Affected: ${AFFECTED_TOP:-unknown}"
    fi
    git -C "$WT" commit -q -m "$(printf '%.68s' "$TITLE") (#$ISSUE_NUM)" -m "$TRAILER_BLOCK" \
      || { git worktree remove "$WT" --force >/dev/null 2>&1 || true
           escalate "could not commit the implement node's work"; }
    log "COMMITTED $(git -C "$WT" rev-parse --short HEAD)"

    # Node 4: validate. NOT a model. Guard first -- a change that touched a protected
    # file has already invalidated everything downstream of it.
    log "NODE validate (no model)"
    python3 factory/guard.py --base "$BASE" --head "$BRANCH" \
      || { git worktree remove "$WT" --force >/dev/null 2>&1 || true
           escalate "protected-path guard failed (FACTORY_RULES.md 6.1) - auto-reject, no fix attempt"; }

    if ! ( cd "$WT" && $FACTORY_VALIDATE_CMD > "$RUNDIR/gate.log" 2>&1 ); then
      log "GATE_RED - the independent validator gets it anyway; the fix node works from its findings"
      tail -20 "$RUNDIR/gate.log" | sed 's/^/    /'
    fi

    git worktree remove "$WT" --force >/dev/null 2>&1 || true

    # Node 5 runs from the ROOT checkout, not the worktree. The PR record is shared
    # factory state and has to survive the worktree being torn down -- written inside it,
    # it went to the bin along with the branch's only copy of the work.
    # `git show` and `git log` are on the list because the review node runs from the ROOT
    # checkout, where the branch's files are not on disk -- `git diff` alone lets it see
    # what changed and not what the changed file now says. It asked for `git show` on all
    # three dispatches of 2026-08-11, was refused each time, and on the third it stopped
    # to ask a human who was not there and wrote no PR record at all. The workflow caught
    # that (the `-s "$PRFILE"` check below), but a node starved of a read-only command it
    # needs fails somewhere downstream of the denial, and the escalation names the
    # symptom. `git fetch` is deliberately NOT here: it mutates refs.
    node review "$MODEL_CHEAP" "$ROOT/factory/prompts/review.md" \
        "Read,Glob,Grep,Bash(git diff:*),Bash(git show:*),Bash(git log:*),Bash(git status:*),Write" \
        || escalate "review node failed"
    [ -s "$PRFILE" ] || escalate "the review node wrote no PR record at $PRFILE"

    # ASSERT THE SHAPE, not just the presence. `-s` only proves the node wrote SOMETHING.
    #
    # The prompts are the one part of this runner you are told to rewrite, and a rewrite
    # can silently drop a field the machinery depends on. Observed exactly once and it
    # cost the whole second half of the loop: a rewritten `review.md` produced a perfectly
    # good human-readable PR record with no front matter, so `state.py` read nothing from
    # it, and `validate-pr` had no branch to check out. The implement lap looked like a
    # complete success and the PR could never be validated by anything.
    #
    # Fail HERE, naming the missing field, rather than three steps later as "no branch".
    for key in issue title state branch; do
      grep -qE "^${key}:[[:space:]]*[^[:space:]]" "$PRFILE" \
        || escalate "the PR record at $PRFILE has no '$key:' in its front matter. The review prompt must emit the full front-matter block (issue/title/state/branch/attempts) - without it the independent validator cannot find the branch and this PR can never be validated."
    done
    log "PR_RECORD_OK front matter complete"

    if [ "$GH" -eq 1 ]; then
      # THE PUSH AND THE PR. Done by the script, from the review node's file -- not by
      # the model. Same rule as the merge: a model's only output is a record, and code
      # decides what happens to it. A node holding `gh pr create` is a node that can open
      # a PR against any branch it likes, including one nothing validated.
      git push -q -u origin "$BRANCH" || escalate "could not push $BRANCH to origin"

      # The `|| true` is what makes the fallback on the next line reachable. Without it a
      # PR record with no `title:` killed the run HERE, one line above the check written
      # to handle exactly that -- the error path existed and the language got there first.
      PR_TITLE="$(grep -m1 '^title:' "$PRFILE" | cut -d: -f2- | sed 's/^ *//' || true)"
      [ -n "$PR_TITLE" ] || PR_TITLE="$TITLE"
      # Body is everything after the front matter, plus the link GitHub acts on.
      python3 -c "import io,sys;t=io.open(sys.argv[1],encoding='utf-8').read();print(t.split('---',2)[2].lstrip() if t.startswith('---') else t)"         "$PRFILE" > "$RUNDIR/pr.body.md"
      printf '\n---\nCloses #%s\n\nOpened by `factory/run-workflow.sh` (implement-issue, run `%s`). No human read this diff.\n' \
        "$ISSUE_NUM" "$RUN" >> "$RUNDIR/pr.body.md"

      # Through the helper, which reads the PR back and asserts GitHub stored the body
      # that was sent. A PR body is a human-facing write like any other, and the one
      # human-facing write this factory has already got wrong went out through a
      # hand-rolled `gh` call. FACTORY_RULES.md 10.1.
      PR_OUT="$(python3 factory/state.py create-pr "$PR_TITLE" "$BASE_BRANCH" "$BRANCH" \
                  < "$RUNDIR/pr.body.md")" \
        || escalate "could not open the pull request, or its body did not survive the round trip"
      printf '%s\n' "$PR_OUT"
      PR_NUM="$(printf '%s' "$PR_OUT" | grep '^PR_NUMBER=' | cut -d= -f2 || true)"
      PR_URL="$(printf '%s' "$PR_OUT" | grep '^PR_URL=' | cut -d= -f2- || true)"
      log "PR_OPENED $PR_URL"

      python3 factory/state.py set "gh:pr:$PR_NUM" state=open \
        || escalate "could not label the new PR"
      echo "$PR_URL" > "$RUNDIR/pr.url"
    fi

    log "PR record written; state=open hands it to the independent validator"
    ;;

  validate-pr)
    BRANCH="$(read_fm branch "$TARGET")"
    [ -n "$BRANCH" ] || escalate "no branch on $TARGET"
    ISSUE_REF="$(read_fm issue "$TARGET")"
    WT=".worktrees/v$ISSUE_NUM"

    if [ "$GH" -eq 1 ]; then
      [ -n "$ISSUE_REF" ] || escalate "the PR does not say which issue it closes; the judge has nothing to judge against"
      materialise "$ISSUE_REF" || escalate "could not read $ISSUE_REF"
      git fetch --quiet origin "$BRANCH:refs/remotes/origin/$BRANCH" 2>/dev/null || true
      CHECKOUT="origin/$BRANCH"
      git rev-parse --verify --quiet "$CHECKOUT" >/dev/null || CHECKOUT="$BRANCH"
    else
      ISSUE_REF="$(read_fm issue "$TARGET")"
      ISSUE_FILE="$ISSUE_REF"
      CHECKOUT="$BRANCH"
    fi

    # --- rebase BEFORE validating, not after being refused ----------------------
    #
    # THE DEADLOCK THIS REMOVES. `merge.sh` refuses a branch that is behind the base, and
    # it is right to: squashing a stale branch silently drops whatever landed while it was
    # in flight. But the designed remedy - "rebase and re-validate" - was unreachable. The
    # gate had already set the PR to `passed`, the refusal then sent it to `needs-human`,
    # and `needs-human` is terminal for nodes. So a branch that went stale for the most
    # ordinary reason in the world (someone pushed to main while a lap was running) parked
    # forever and needed a human to hand-edit a file.
    #
    # On a repo with any commit velocity that is not an edge case, it is Tuesday.
    #
    # Rebasing HERE is safe in a way that rebasing after a verdict is not: nothing has been
    # judged yet. Everything downstream - the guard, the full gate, the judge - then runs
    # against the rebased tree, so the verdict describes the thing that will actually be
    # merged. A conflict is a genuine human problem and escalates.
    if git merge-base --is-ancestor "$BASE" "$CHECKOUT" 2>/dev/null; then
      log "REBASE_NOT_NEEDED $CHECKOUT already contains $BASE"
    else
      log "REBASE_REQUIRED $CHECKOUT is behind $BASE - rebasing before validation"
      # THE REBASE RUNS IN ITS OWN DISPOSABLE WORKTREE, never in the shared checkout
      # (structural fix, Rick's go 2026-08-17 — retires the whole incident class the
      # shared-checkout rebase produced in ONE day: a dirty-tree refusal misreported
      # as a conflict at 12:55, then the post-rebase restore stranding the checkout
      # on main at 13:55, torching every later script launch). refs/heads/$BRANCH is
      # shared through the common gitdir, so a rebase inside the worktree updates the
      # branch exactly as before — but the shared checkout never moves, a dirty
      # shared tree can no longer block anyone else's lap, and there is no restore
      # step left to get wrong. Stderr is captured, not discarded, and only git's
      # own CONFLICT marker earns the word "conflict" (evolution recs, lap #20).
      REBASE_LOG="$RUNDIR/rebase.log"
      RB_WT=".worktrees/rb$ISSUE_NUM"
      prepare_worktree_path "$RB_WT"
      git worktree add "$RB_WT" "$BRANCH" >"$REBASE_LOG" 2>&1 \
        || { prepare_worktree_path "$RB_WT"
             escalate "could not check out $BRANCH into an isolated worktree for the pre-validation rebase (see $REBASE_LOG). This is a machinery failure, not a merge decision."; }
      REBASE_OK=no
      if git -C "$RB_WT" rebase "$BASE" >>"$REBASE_LOG" 2>&1; then
        REBASE_OK=yes
      elif settle_index_conflicts "$RB_WT" >>"$REBASE_LOG" 2>&1; then
        # The only unmerged path was the generated MIGRATIONS.md (issue #64's shape);
        # regenerating it from the tree resolved every stop and the rebase completed.
        REBASE_OK=yes
        log "REBASE_INDEX_CONFLICT_SETTLED MIGRATIONS.md conflicts resolved by regeneration (generated file; migration-number race, issue #64)"
      fi
      if [ "$REBASE_OK" = yes ]; then
        # Duplicate-number check runs on EVERY completed rebase, not only the settled
        # ones — the collision is what makes the index conflict, but nothing
        # guarantees the conflict is what surfaces it.
        if ! renumber_duplicate_migrations "$RB_WT"; then
          prepare_worktree_path "$RB_WT"
          escalate "the branch adds a migration whose 00NNN number is already taken on $BASE and the mechanical renumber could not settle it without a choice (see $RUNDIR/RENUMBERED and $REBASE_LOG if present). A human must renumber per the vox-database-migrations skill; the factory will not guess. (issue #64)"
        fi
        prepare_worktree_path "$RB_WT"
        log "REBASED $BRANCH onto $BASE in an isolated worktree; everything below judges the rebased tree"
        [ "$GH" -eq 1 ] && { git push -q --force-with-lease origin "$BRANCH" || log "REBASE_PUSH_FAILED (validating locally)"; }
        CHECKOUT="$BRANCH"
        # LOUD in the audit trail (Factory Resume's condition on the issue-#64 design):
        # a mechanically rewritten branch must say so where the judged diff is read —
        # on the PR itself, plus the RENUMBERED marker in the run dir and the log
        # lines above. Never fatal: the rewrite already happened and is recorded.
        if [ -s "$RUNDIR/RENUMBERED" ]; then
          { echo "**Migration renumbered during the pre-validation rebase** (migration-number race, issue #64). Mechanical only — rename + header number + regenerated index; migration content untouched. Everything below judged the renumbered tree."
            echo
            sed 's/^/- /' "$RUNDIR/RENUMBERED"; } | note "$TARGET" \
            || log "RENUMBER_NOTE_FAILED — the renumber is still recorded in $RUNDIR/RENUMBERED and the log above"
        fi
      else
        git -C "$RB_WT" rebase --abort >/dev/null 2>&1 || true
        prepare_worktree_path "$RB_WT"
        if grep -q '^CONFLICT' "$REBASE_LOG"; then
          escalate "$BRANCH conflicts with $BASE and cannot be rebased automatically ($(grep -c '^CONFLICT' "$REBASE_LOG") conflict marker(s) - see $REBASE_LOG). A human has to resolve the conflict; the factory will not guess at a merge."
        else
          escalate "rebasing $BRANCH onto $BASE failed for a reason other than a content conflict (no CONFLICT marker in $REBASE_LOG). This is a machinery failure, not a merge decision - read $REBASE_LOG before touching the branch."
        fi
      fi
    fi

    prepare_worktree_path "$WT"
    git worktree add --detach "$WT" "$CHECKOUT" >/dev/null 2>&1 || escalate "could not check out $CHECKOUT"
    provision_worktree "$WT"

    # Governance from the BASE branch, before the branch under review is read. On GitHub
    # that is origin/main and not the local main -- reading the local copy would judge the
    # branch against whatever this checkout happened to have fetched, which is a rulebook
    # nobody published.
    git show "$BASE:MISSION.md"       > "$RUNDIR/MISSION.base.md"
    git show "$BASE:FACTORY_RULES.md" > "$RUNDIR/FACTORY_RULES.base.md"
    git show "$BASE:CLAUDE.md"        > "$RUNDIR/CLAUDE.base.md"

    # Exit-code-honest (evolution rec, PR #21's second park): exit 1 means the tripwire
    # TRIPPED; anything else means it could not run or failed internally. A machinery
    # failure is not evidence of contamination, and the two must never share an
    # escalation message -- the park that motivated this asserted "builder artifact"
    # when the script never launched. Output is saved to the run, not discarded.
    TRIP_LOG="$RUNDIR/tripwire.log"
    if python3 factory/tripwire.py "$WT" >"$TRIP_LOG" 2>&1; then
      cat "$TRIP_LOG"
    else
      TRIP_RC=$?
      cat "$TRIP_LOG"
      git worktree remove "$WT" --force >/dev/null 2>&1 || true
      if [ "$TRIP_RC" -eq 1 ]; then
        escalate "TRIPWIRE: a builder artifact is in the validator's tree (see $TRIP_LOG); its verdict is not independent"
      else
        escalate "TRIPWIRE CHECK COULD NOT RUN (exit $TRIP_RC - see $TRIP_LOG). This is a machinery failure, not evidence of contamination - check that the root checkout is on the base branch."
      fi
    fi

    # Guarded, like every other state write here. Unguarded, a refusal exits this script
    # on the spot with `set -e` and no escalation -- the same silent shape that made the
    # fix loop unreachable. This is also the write that CLAIMS the PR: everything below
    # assumes a validation owns it.
    python3 factory/state.py set "$TARGET" state=validating \
      || { git worktree remove "$WT" --force >/dev/null 2>&1 || true
           escalate "could not move $TARGET to 'validating'; the validation cannot claim a PR it is not allowed to hold"; }

    # The guard runs from the ROOT checkout against the branch -- NOT from inside the
    # worktree. Running it in the worktree executes the BRANCH's copy of the enforcement
    # code, so a PR supplies the guard that judges it. factory/** is protected, so a PR
    # cannot deliberately weaken it -- but a branch cut before a guard fix silently runs
    # the old, broken guard, which is exactly how this was found. Same principle as
    # reading governance from the base branch (FACTORY_RULES.md 9), applied to the code
    # that does the enforcing rather than the rules it enforces.
    python3 factory/guard.py --base "$BASE" --head "$CHECKOUT" > "$RUNDIR/gate.log" 2>&1 \
      || { git worktree remove "$WT" --force >/dev/null 2>&1 || true
           # `|| true`, because a command inside a `|| { ... }` block does NOT chain: under
           # set -e a failure here aborts the whole block, so `escalate` on the next line
           # never runs. Verified: `false || { false; echo B; }` never prints B and exits 1.
           # That would turn a protected-path guard failure -- a PR touching factory/** --
           # into an exit 1 with no escalation and no notification, on the one path whose
           # entire job is to stop a branch from rewriting its own enforcement code.
           python3 factory/state.py set "$TARGET" state=rejected || true
           escalate "protected-path guard failed on the branch under review"; }

    # The unit family's disjoint-files retry (harness/ci.py run_counted, evolution rec
    # lap #22) needs the diff's own changed files to prove a failing suite has no
    # causal link to the change under validation.
    export FACTORY_DIFF_FILES="$(git diff --name-only "$BASE...$CHECKOUT")"
    ( cd "$WT" && $FACTORY_VALIDATE_CMD ) >> "$RUNDIR/gate.log" 2>&1 || log "GATE_RED"

    git diff "$BASE...$CHECKOUT" > "$RUNDIR/diff.patch"
    git log --format='%h %s' "$BASE..$CHECKOUT" > "$RUNDIR/commits.txt"
    log "DIFF_RENDERED $(wc -l < "$RUNDIR/diff.patch") lines -> $RUNDIR/diff.patch"

    # `git show`/`git log` added 2026-08-18 (Rick's direction): the lap-#17 prompt
    # guidance ("Read the file instead") did not stop the judge reaching for
    # `git show HEAD --stat` on PR #23's revalidation — denied twice, recovered, but a
    # judge starved of a read-only command wastes turns right where the verdict forms.
    # Same reasoning as the review node's list above; `git fetch` stays out (mutates refs).
    ( cd "$WT" && node judge "$MODEL_CHEAP" "$ROOT/factory/prompts/judge.md" \
        "Read,Bash(git diff:*),Bash(git show:*),Bash(git log:*),Write" ) || escalate "judge node failed"

    # The verdict must exist before the worktree goes. It is written to the absolute run
    # dir for the same reason the plan is: a path relative to the judge's cwd lands inside
    # the worktree and dies with it. gate.sh did correctly refuse to read a missing verdict
    # as an approval -- but the last backstop should not be the thing that catches this.
    [ -s "$RUNDIR/verdict.json" ] \
      || { git worktree remove "$WT" --force >/dev/null 2>&1 || true
           escalate "the judge node produced no verdict at $RUNDIR/verdict.json"; }

    # Node 3 (Rick's directive 2026-08-17, docs/factory/assumptions-judge.md): the
    # assumptions judge. Runs ONLY when this lap recorded assumptions, and reads them
    # under the same key the implement flow writes -- no re-derivation, the dial-2
    # key-mismatch class stays structurally impossible. One-way authority: gate.sh
    # treats a missing, malformed, or failed verdict exactly like needs_human, so
    # every failure here LOGS and falls through to the human hold instead of
    # escalating -- fail-closed is the point, not an incident.
    ASSUMPTIONS_SRC=".factory/assumptions/$ISSUE_ID.txt"
    if [ ! -s "$ASSUMPTIONS_SRC" ] && [ "$GH" -eq 1 ]; then
      # THIRD SIGHTING of the dial-2 key-mismatch class (2026-08-17, PR #23): a
      # gh:pr:N target keys ISSUE_ID by the PR number, but implement wrote the
      # assumptions under the ISSUE number -- so this lookup missed and the judge
      # silently skipped on every real gh:pr lap. Resolve the linked issue exactly
      # the way gate.sh's own two-step assumption lookup does.
      LINKED_ISSUE="$(python3 factory/state.py get "$TARGET" 2>/dev/null | grep '^issue=' | head -1 | cut -d= -f2- || true)"
      [ -n "${LINKED_ISSUE:-}" ] \
        && ASSUMPTIONS_SRC=".factory/assumptions/$(basename "${LINKED_ISSUE%.md}" | sed 's/^gh[:-]//' | tr ':' '-').txt"
    fi
    if [ -s "$ASSUMPTIONS_SRC" ]; then
      cp "$ASSUMPTIONS_SRC" "$RUNDIR/assumptions.txt"
      # A given assumptions CONTENT is judged once (issue #63, Rick's directive
      # 2026-08-20): PR #38's revalidation re-rolled a fresh judge on a byte-identical
      # file and got a different ruling AND a different block segmentation (9/9
      # all_benign became 7-reviewed needs_human). An exact-hash match replays the
      # first PARSED ruling verbatim -- flagged replays as flagged, so reuse can only
      # ever repeat a ruling, never soften one; acceptance still travels through
      # labels. Any content change misses the hash and re-judges in full.
      A_SHA="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$ASSUMPTIONS_SRC")"
      A_STORE="${ASSUMPTIONS_SRC%.txt}.verdict.json"
      A_REUSED=no
      if [ -s "$A_STORE" ]; then
        A_REUSED="$(python3 - "$A_STORE" "$A_SHA" "$RUNDIR/assumptions-verdict.json" <<'PY'
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    if s.get("sha256") == sys.argv[2] and isinstance(s.get("ruling"), dict) and "verdict" in s["ruling"]:
        r = dict(s["ruling"])
        r["reused_from_run"] = s.get("run", "?")
        r["reused_sha256"] = s["sha256"]
        json.dump(r, open(sys.argv[3], "w"), indent=2)
        print("yes")
    else:
        print("no")
except Exception:
    print("no")
PY
)"
      fi
      if [ "$A_REUSED" = "yes" ]; then
        log "ASSUMPTIONS_RULING_REUSED sha256=$A_SHA from=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('run','?'))" "$A_STORE") - byte-identical content, the first parsed ruling replays (flagged stays flagged)"
      else
        ( cd "$WT" && node assumptions-judge "$MODEL_CHEAP" "$ROOT/factory/prompts/assumptions-judge.md" \
            "Read,Write" ) || log "ASSUMPTIONS_JUDGE_FAILED - the hold falls back to a human (fail-closed)"
        # Persist ONLY a ruling that parses with a verdict field, keyed to the exact
        # bytes it judged, carrying the run id (audit trail) and the blank-line block
        # count gate.sh's truncation check reads. An unparseable verdict is never
        # persisted -- the next run re-judges (fail-closed).
        if [ -s "$RUNDIR/assumptions-verdict.json" ]; then
          A_BLOCKS_NOW="$(awk 'BEGIN{RS=""} {n++} END{print n+0}' "$RUNDIR/assumptions.txt")"
          python3 - "$RUNDIR/assumptions-verdict.json" "$A_STORE" "$A_SHA" "$RUN" "$A_BLOCKS_NOW" <<'PY' || log "ASSUMPTIONS_RULING_NOT_PERSISTED - verdict did not parse; the next run re-judges (fail-closed)"
import json, sys
r = json.load(open(sys.argv[1]))
assert "verdict" in r
json.dump({"sha256": sys.argv[3], "run": sys.argv[4], "blocks": int(sys.argv[5]), "ruling": r},
          open(sys.argv[2], "w"), indent=2)
PY
        fi
      fi
      [ -s "$RUNDIR/assumptions-verdict.json" ] \
        || log "ASSUMPTIONS_JUDGE_NO_VERDICT - gate.sh holds for a human (fail-closed)"
    fi

    git worktree remove "$WT" --force >/dev/null 2>&1 || true

    # GUARDED, and the guard earned its place on the first live red gate (Phase F,
    # dial-2 cycle on gh:pr:16): gate.sh's fail() had already parked the PR, written
    # the ledger, notified AND commented — then this line's exit 1 tripped the runner's
    # ERR trap, which escalated the same failure a second time (two notifications, two
    # PR comments, and a RUNNER_FAULT naming a fault that did not exist). Exit 1 IS
    # gate.sh's designed everything-already-reported ending; anything else from it is a
    # real machinery fault and still escalates.
    GATE_RC=0
    bash factory/gate.sh "$TARGET" "$RUNDIR/gate.log" "$RUNDIR/verdict.json" || GATE_RC=$?
    case "$GATE_RC" in
      0) : ;;
      1) log "GATE_BLOCKED $TARGET - gate.sh parked it and escalated (see its output above); not a runner fault" ;;
      *) escalate "gate.sh exited $GATE_RC without parking the work - machinery fault, not a verdict" ;;
    esac
    ;;

  fix-pr)
    ATTEMPTS="$(read_fm attempts "$TARGET")"
    [ "${ATTEMPTS:-0}" -lt 2 ] || escalate "fix-attempt cap reached (FACTORY_RULES.md 8)"

    # THE FINDINGS, written by gate.sh when it recorded `request_changes`. ABSOLUTE,
    # because the fix node cd's into its worktree and a relative path resolves there.
    #
    # Asserted, not assumed. A fix node with no findings does not fail - it re-reads the
    # diff and invents an objection, which is how you get a confident commit that
    # addresses nothing and burns one of two attempts. Missing findings mean the gate
    # never recorded them, which is a machinery fault and belongs in front of a human.
    FINDINGS_KEY="$(printf '%s' "$TARGET" | tr '/.:\\' '----')"
    FINDINGS="$ROOT/.factory/findings/$FINDINGS_KEY.json"
    FINDINGS_LOG="$ROOT/.factory/findings/$FINDINGS_KEY.gate.log"
    [ -s "$FINDINGS" ] || escalate "no validator findings at $FINDINGS - gate.sh records them when it returns request_changes, so this PR reached the fix loop without a recorded objection. A fix node with nothing to read would invent one."
    log "FINDINGS $FINDINGS ($(wc -c < "$FINDINGS") bytes)"

    BRANCH="$(read_fm branch "$TARGET")"
    ISSUE_REF="$(read_fm issue "$TARGET")"
    [ "$GH" -eq 1 ] && { materialise "$ISSUE_REF" || escalate "could not read $ISSUE_REF"; } \
                    || ISSUE_FILE="$ISSUE_REF"
    WT=".worktrees/f$ISSUE_NUM"
    prepare_worktree_path "$WT"
    git worktree add "$WT" "$BRANCH" >/dev/null 2>&1 || escalate "could not check out $BRANCH"
    provision_worktree "$WT"

    ( cd "$WT" && node fix "$MODEL_CHEAP" "$ROOT/factory/prompts/fix.md" \
        "Read,Glob,Grep,Edit,Write,Bash($FACTORY_VALIDATE_QUICK)" ) \
      || { git worktree remove "$WT" --force >/dev/null 2>&1 || true; escalate "fix node failed"; }

    if [ -z "$(git -C "$WT" status --porcelain)" ]; then
      git worktree remove "$WT" --force >/dev/null 2>&1 || true
      escalate "the fix node changed nothing; the finding is not addressed by an empty diff"
    fi
    git -C "$WT" add -A
    FIX_AFFECTED="$(git -C "$WT" diff --cached --name-only 2>/dev/null | cut -d/ -f1-2 | sort -u | paste -sd ',' - | head -c 120 || true)"
    git -C "$WT" commit -q -m "fix: address validator findings (attempt $((ATTEMPTS + 1))) (#$ISSUE_NUM)" \
      -m "Epic: factory
Story: issue-$ISSUE_NUM
Type: fix
Learning: none recorded
Affected: ${FIX_AFFECTED:-unknown}"
    if [ "$GH" -eq 1 ]; then
      git -C "$WT" push -q origin "HEAD:$BRANCH" || escalate "could not push the fix"
    fi

    git worktree remove "$WT" --force >/dev/null 2>&1 || true
    python3 factory/state.py bump-attempt "$TARGET" \
      || escalate "the fix is committed but the attempt counter did not move; another fix would not be counted and the cap would never be reached"

    # ONE transition, to `open`, and it used to be two: `validating` then `open`. The
    # second was illegal (validating cannot reach open), returned 1, and `set -e` killed
    # this workflow on that line -- before the escalate below could exist, before
    # needs-human, before any notification. The PR stayed `validating`, `next` did not
    # look at that state, and the dispatcher answered `idle` from then on. The fix was
    # committed and the loop simply stopped, silently, on the one workflow that had never
    # been run.
    #
    # `open` is the right target on its own: a fixed PR is a PR waiting to be validated.
    # The dispatcher picks it up and validate-pr sets `validating` itself after the
    # tripwire, which is the only place allowed to.
    python3 factory/state.py set "$TARGET" state=open \
      || escalate "the fix is committed on $BRANCH but the PR could not be returned to 'open' for re-validation; it would otherwise sit in a state the dispatcher does not look at"
    log "fixed; back to the independent validator (attempt $((ATTEMPTS + 1))/2)"
    ;;

  triage)
    materialise "$TARGET" || escalate "could not read the issue"

    node sort "$MODEL_CHEAP" "$ROOT/factory/prompts/triage.md" \
      "Read,Glob,Grep,Write" \
      || escalate "triage node failed"

    # THE DECISION IS APPLIED BY CODE, NOT BY THE MODEL. The triage node writes a
    # disposition file and nothing else; this applies it through state.py, which refuses
    # an illegal transition. Before the move the node edited the issue's front matter
    # directly -- so it could write ANY state, including one the transition table forbids,
    # and the table was never consulted. That hole existed on the file backend too; the
    # GitHub move is only what made it visible, because there is no front matter to edit.
    DEC="$RUNDIR/triage.json"
    [ -s "$DEC" ] || escalate "the triage node wrote no decision at $DEC"
    python3 - "$DEC" <<'PY' > "$RUNDIR/triage.env" || escalate "triage decision is not readable JSON"
import json, sys, shlex
d = json.load(open(sys.argv[1], encoding="utf-8"))
st = d.get("state", "")
if st not in {"accepted", "deferred", "rejected", "needs-human"}:
    raise SystemExit(f"triage returned an unknown disposition: {st!r}")
print(f"DEC_STATE={shlex.quote(st)}")
print(f"DEC_PRIORITY={shlex.quote(d.get('priority') or '')}")
print(f"DEC_AREA={shlex.quote(d.get('area') or '')}")
PY
    . "$RUNDIR/triage.env"

    # ONE process, one string, one verified write. The pipeline this replaces echoed a
    # header, piped a `python3 -c` through the platform codepage, and handed the result to
    # a `gh` flag that does not read files -- so the correct rejection on issue #3 reached
    # GitHub as the two characters `@-`, and nothing noticed, because the only thing
    # checked afterwards was the exit code. FACTORY_RULES.md 10.1.
    python3 factory/state.py triage-note "$TARGET" "$DEC"       || escalate "the decision was made but could not be published; a verdict the filer cannot read is not a verdict"

    if [ -n "$DEC_PRIORITY" ]; then
      python3 factory/state.py set "$TARGET" "priority=$DEC_PRIORITY" || true
    fi
    python3 factory/state.py set "$TARGET" "state=$DEC_STATE" \
      || escalate "triage proposed an illegal transition to '$DEC_STATE'"
    log "TRIAGED $TARGET -> $DEC_STATE"

    # A TRIAGE THAT DECIDES `needs-human` MUST REACH A HUMAN.
    #
    # This wrote the ledger line inline and stopped there, so `factory_notify` was never
    # called: the notifier is reached only from `escalate()`, and `escalate()` fires on
    # runner FAULTS - a node that crashed, unreadable JSON, an illegal transition. A
    # successful triage that correctly decides "a human must look at this" is not a fault,
    # so it took the one path that skips the alarm.
    #
    # Measured: seven probe issues, two correct `needs-human` decisions, **zero
    # notifications** - the directory was never even created. The stop list worked
    # perfectly and nobody was told. That is precisely what the comment on escalate()
    # warns about: "if it cannot interrupt a human, unattended quietly means unmonitored".
    #
    # Not routed through `escalate()` itself, because that also flips the issue to
    # `needs-human` (already done, through the transition table) and exits 3, which would
    # turn a correct triage into a failed workflow. The notification is the only missing
    # half, so that is the half added.
    if [ "$DEC_STATE" = "needs-human" ]; then
      TRIAGE_WHY="$(python3 -c "import json,sys;print((json.load(open(sys.argv[1],encoding='utf-8')).get('note') or 'escalated at triage').strip().replace(chr(10),' ')[:300])" "$DEC" 2>/dev/null || echo "escalated at triage")"
      echo "- $(date -u +%FT%TZ)  $TARGET  (triage)  $TRIAGE_WHY" >> .factory/needs-human.md
      log "$(factory_notify "$TARGET" "(triage) $TRIAGE_WHY")"
    fi
    ;;

  *)
    echo "unknown workflow '$WORKFLOW'" >&2
    exit 1 ;;
esac

log "WORKFLOW_DONE $WORKFLOW"
