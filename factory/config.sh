#!/usr/bin/env bash
# THE CONFIGURATION SURFACE — the VOX dark factory (dark-factory program, Phase C).
# This is the file you edit; the rest of factory/ is machinery you should be able to
# leave alone. Every project-specific value in the runner reads from here.
#
# Sourced by every script in factory/. Keep it to variable assignments; no side effects,
# nothing that can fail, nothing that prints.

# --- the agent ---------------------------------------------------------------
# ONE EXECUTABLE, NO ARGUMENTS. `run-workflow.sh` invokes this as "$AGENT" -p ..., so the
# whole value is treated as a single command name. Flags verified against `claude --help`
# on 2026-08-15: --allowedTools --disallowedTools --permission-mode --max-budget-usd
# --add-dir --output-format --model all present.
FACTORY_AGENT="${FACTORY_AGENT:-claude}"

# Model routing: premium in the PLAN slot, cheaper elsewhere (FACTORY_RULES.md §8).
# One premium slot buys most of the quality of two.
FACTORY_MODEL_PREMIUM="${FACTORY_MODEL_PREMIUM:-opus}"
FACTORY_MODEL_CHEAP="${FACTORY_MODEL_CHEAP:-sonnet}"

# A COST guard, not a safety gate — a DOLLAR cap, never a turn cap (the CLI silently
# ignores flags it does not have; a guard that silently does not apply is worse than
# none). High enough that hitting it means something went wrong.
FACTORY_MAX_BUDGET_USD="${FACTORY_MAX_BUDGET_USD:-8}"

# --- the validation harness --------------------------------------------------
# THE MOST IMPORTANT LINE IN THIS FILE. Component 5 is the Phase B harness: one command,
# positive markers with counts, non-zero on broken, `.factory/STOP` checked before any
# rung. The full map is docs/factory/phase-b-validation-harness.md.
# This machine has no bare `python`; the gate is python3 everywhere.
FACTORY_VALIDATE_CMD="${FACTORY_VALIDATE_CMD:-python3 harness/ci.py}"

# The strict subset an implementing node may run on itself while it works
# (eslint + tsc + jest unit; ~4 min, no API spend). The real gate runs independently
# afterwards regardless of what this said.
FACTORY_VALIDATE_QUICK="${FACTORY_VALIDATE_QUICK:-python3 harness/ci.py --quick}"

# EMPTY IS NOT PASS, expressed as data. Every marker named here must appear in the run
# log or the gate refuses to merge — the gate never asks "did anything fail?", it asks
# "did this specific thing report that it ran?"
#
# Two lists, on purpose. When the repo carries the real VOX gate (harness/e2e.py — the
# Phase B validation harness), every ladder family must have reported with counts
# (FACTORY_RULES.md §3; MUTATIONS_DEFERRED is expected per lap — the mutation proof runs
# via --prove before dial changes, never per lap). The machinery fixture that
# scripts/_test_runner.py builds carries a stub gate with no harness/e2e.py, and gets the
# template's core four: the two gates that must be code, the guard, and the summary.
if [ -f "harness/e2e.py" ]; then
  FACTORY_REQUIRED_MARKERS="${FACTORY_REQUIRED_MARKERS:-STATIC_OK UNIT_PASSED EF_UNIT_PASSED FIDELITY_OK INTEGRATION_PASSED DENO_INTEGRATION_PASSED APP_STARTED E2E_PIPELINE_PASSED E2E_QUERY_PASSED HOLDOUT_PASSED COMPILE_EVAL_PASSED FLOOR_OK PROTECTED_OK GATE_OK}"
  # The migration rung (Rick, 2026-08-17): the real VOX harness carries ci.py's
  # `migrations` family, so its log must always hold a conclusion —
  # MIGRATION_LINT_NONE or MIGRATION_REPLAY_OK. The fixture stub has no rung and
  # is not failed for a marker its validator cannot print (branch above).
  FACTORY_REQUIRE_MIGRATION_CONCLUSION="${FACTORY_REQUIRE_MIGRATION_CONCLUSION:-1}"
  # The territory-expansion rungs (Rick, 2026-08-18): client Drizzle migrations
  # and the native surface each conclude conditionally, exactly like the
  # migration rung — DRIZZLE_LINT_NONE|DRIZZLE_LINT_OK and
  # NATIVE_COMPILE_NONE|NATIVE_COMPILE_OK. A log with no conclusion fails.
  FACTORY_REQUIRE_DRIZZLE_CONCLUSION="${FACTORY_REQUIRE_DRIZZLE_CONCLUSION:-1}"
  FACTORY_REQUIRE_NATIVE_CONCLUSION="${FACTORY_REQUIRE_NATIVE_CONCLUSION:-1}"
else
  FACTORY_REQUIRED_MARKERS="${FACTORY_REQUIRED_MARKERS:-APP_STARTED E2E_PASSED PROTECTED_OK GATE_OK}"
  FACTORY_REQUIRE_MIGRATION_CONCLUSION="${FACTORY_REQUIRE_MIGRATION_CONCLUSION:-0}"
  FACTORY_REQUIRE_DRIZZLE_CONCLUSION="${FACTORY_REQUIRE_DRIZZLE_CONCLUSION:-0}"
  FACTORY_REQUIRE_NATIVE_CONCLUSION="${FACTORY_REQUIRE_NATIVE_CONCLUSION:-0}"
fi

# The e2e-step floor the TEMPLATE gate reads. The VOX floor is richer — the exact+min
# ratchet in .factory/locks/floor.json is enforced INSIDE ci.py (FLOOR_OK is a required
# marker above), so this template-level key stays as shipped and simply reports 0/unset.
FACTORY_E2E_FLOOR_FILE="${FACTORY_E2E_FLOOR_FILE:-.factory/locks/floor.json}"
FACTORY_E2E_FLOOR_KEY="${FACTORY_E2E_FLOOR_KEY:-e2e_steps_asserted}"

# --- the TestFlight MT road (territory expansion, Rick 2026-08-18) -----------
# factory/tf-build.sh — internal/preview lane only, idle/held ticks only,
# non-gating. FACTORY_RULES §2 item 11. The ASC identifiers default inside the
# script; override here only if the key or app ever changes.
FACTORY_TF_ENABLED="${FACTORY_TF_ENABLED:-1}"
FACTORY_TF_PATHS="${FACTORY_TF_PATHS:-src/ modules/ assets/ app.config.ts app.json babel.config.js metro.config.js}"

# --- the base branch (program decision D2) -----------------------------------
# The factory targets DEVELOP — Rick's workbench. develop -> main stays Rick's call via
# /ship-to-main, forever ("main is Rick's known-good"). merge.sh refuses a configured
# base of main outright. On a checkout where this branch does not exist (the machinery
# fixture scripts/_test_runner.py builds), the runner falls back to main, which is that
# fixture's base.
FACTORY_BASE_BRANCH="${FACTORY_BASE_BRANCH:-develop}"

# --- state -------------------------------------------------------------------
# `github` wherever an origin remote exists (this repo: your-org/your-repo, private, D6);
# `files` for a local clone with no remote — what the machinery tests use.
FACTORY_BACKEND="${FACTORY_BACKEND:-}"

# --- the dial ----------------------------------------------------------------
# 0 workflows exist, run by hand   <- Phase C shipped here; Phase D proved laps by hand
# 1 accepted issue -> implement dispatches (PR opens, then everything holds)
#                                  <- notched 2026-08-16 (cycle watched: PR #16
#                                     built unattended, validate HELD at the dial)
# 2 + validate-pr dispatches (full gate + judge, verdict written; merge holds)
#                                  <- notched 2026-08-16 on Rick's explicit go,
#                                     fresh --prove GATE_OK mode=prove first
# 3 is the destination per D2 — auto-merge green work into develop. Each further
# notch: --prove green, then Rick's explicit go, one notch per go, never a batch.
#                                  <- notched 2026-08-16 on Rick's explicit go,
#                                     fresh --prove GATE_OK mode=prove (8/8) first;
#                                     D2 reached — the climb ends here (dial 4+ is
#                                     not a Phase F decision)
FACTORY_AUTONOMY="${FACTORY_AUTONOMY:-3}"

FACTORY_MAX_PARALLEL="${FACTORY_MAX_PARALLEL:-1}"
FACTORY_MAX_FIX_ATTEMPTS="${FACTORY_MAX_FIX_ATTEMPTS:-2}"

# Lock reaping: a lock whose PID is gone is reaped after GRACE minutes; STALE is the
# fallback when the PID cannot be checked. A full VOX lap runs 12-15 minutes; 180 is
# generous headroom, not a measurement.
FACTORY_LOCK_STALE_MINUTES="${FACTORY_LOCK_STALE_MINUTES:-180}"
FACTORY_LOCK_GRACE_MINUTES="${FACTORY_LOCK_GRACE_MINUTES:-5}"

# --- the stop button ---------------------------------------------------------
# Two, on purpose (FACTORY_RULES.md §8): the local file works with the network down
# (ci.py checks it too, before any rung), and the `factory:stop` label is reachable from
# a phone and FAILS CLOSED — an unreadable stop state halts every dispatch.
FACTORY_STOP_FILE="${FACTORY_STOP_FILE:-.factory/STOP}"
FACTORY_STOP_LABEL="${FACTORY_STOP_LABEL:-factory:stop}"

# --- limits (FACTORY_RULES.md §2) --------------------------------------------
FACTORY_SIZE_CAP="${FACTORY_SIZE_CAP:-500}"
FACTORY_FILE_CAP="${FACTORY_FILE_CAP:-12}"

# --- worktree provisioning ---------------------------------------------------
# The gate cannot run from a bare worktree: node_modules is multi-GB and the serve-env
# inputs are gitignored, so none of them arrive with a checkout. The runner symlinks
# each of these from the root checkout into every worktree it creates (skipping any that
# do not exist). All are gitignored, so a worktree `git add -A` can never sweep one up.
# platform-bulletin.md is gitignored (auto-updated daily), so a fresh worktree never
# carries it; linked in so the prime node reads the LIVE bulletin, not nothing
# (Phase D lap 1, patch 3 bundle).
FACTORY_WORKTREE_LINKS="${FACTORY_WORKTREE_LINKS:-node_modules supabase/functions/.env .env.local _bmad/_memory/platform-bulletin.md}"

# --- deployment (component 3) — Phase E --------------------------------------
# The D1 territory's deployable surface is Supabase Edge Functions, shipped by
# factory/deploy.sh with the supabase CLI. Prod DB apply is PERMANENTLY human
# (03 §4.4); deploy.sh refuses any range containing a migration. First-time function
# deploys are human (new surface = a judgement); the payment surfaces below never
# auto-deploy at all — same list as the FACTORY_RULES.md §5 protected payment paths.
FACTORY_DEPLOY_PROJECT_REF="${FACTORY_DEPLOY_PROJECT_REF:-YOUR_PROJECT_REF}"
FACTORY_DEPLOY_EXCLUDE="${FACTORY_DEPLOY_EXCLUDE:-fn-create-checkout fn-stripe-webhook}"
FACTORY_EF_BASE_URL="${FACTORY_EF_BASE_URL:-https://YOUR_PROJECT_REF.supabase.co/functions/v1}"
# Optional DEEP canary run after the built-in verification (version bump + ACTIVE +
# import map) and per-function boot probes, which are mandatory and not configurable.
# Empty = skipped; when set, every marker must appear or the run rolls back.
FACTORY_HEALTH_CMD="${FACTORY_HEALTH_CMD:-}"
FACTORY_HEALTH_MARKERS="${FACTORY_HEALTH_MARKERS:-}"

# Prod DB apply (the "Last Step", Rick 2026-08-17): factory/db-apply.sh applies a
# merged range's NEW migrations via the same Management API endpoint MCP
# apply_migration uses — static allowlist, then the independent migration judge,
# with a human floor for data destruction and the money/identity schemas
# (FACTORY_RULES §2.4a). The policy file carries the same defaults so a bare
# environment fails closed identically. Token: keychain 'dark-factory-db-token'
# (SUPABASE_ACCESS_TOKEN env overrides).
FACTORY_DB_HOT_TABLES="${FACTORY_DB_HOT_TABLES:-recordings entries search_chunks transcripts photos reports report_entries report_sections pipeline_stage_events pipeline_runs recording_compositions}"
FACTORY_DB_PROTECTED_SCHEMAS="${FACTORY_DB_PROTECTED_SCHEMAS:-auth storage marketing realtime vault supabase_migrations supabase_functions pgsodium graphql extensions cron net}"
FACTORY_DB_PROTECTED_TABLES="${FACTORY_DB_PROTECTED_TABLES:-profiles organizations organization_members company_members project_members project_companies memberships}"
FACTORY_DB_FLOOR_SCHEMAS="${FACTORY_DB_FLOOR_SCHEMAS:-auth marketing vault supabase_migrations pgsodium}"
FACTORY_DB_JUDGE_MODEL="${FACTORY_DB_JUDGE_MODEL:-$FACTORY_MODEL_PREMIUM}"
FACTORY_DB_JUDGE_BUDGET="${FACTORY_DB_JUDGE_BUDGET:-4}"

# --- the post-lap evolution loop + brain seed (Phase G) ----------------------
# factory/evolve.sh reviews a decided lap's PROCESS (one cheap capped session; its
# writes are scoped to .factory/evolution/ — recommendations are proposals, applying
# one is a human commit). factory/brain-seed.sh appends fact-only merged-lap records
# to the Construction OS Brain. Wired into the tick's catch-up paths at dial 3
# (post-merge, idle, and held ticks — Rick's go at Phase G acceptance); the same
# commands remain the hand-run path at any dial.
FACTORY_EVOLVE_MODEL="${FACTORY_EVOLVE_MODEL:-$FACTORY_MODEL_CHEAP}"
FACTORY_EVOLVE_BUDGET="${FACTORY_EVOLVE_BUDGET:-3}"

# The 9b auto-apply channel (Rick, 2026-08-18): factory/evolve-apply.sh applies the
# PROMPT-ONLY subset of evolve's proposals — eligibility is factory/prompts/*.md and
# nothing else (never the gate, guard, runner, governance, the DB judge's prompts, or
# this channel's own prompts) — through deterministic checks plus an independent
# premium-model judge, park-by-default. Everything else stays a human commit (9a).
FACTORY_EVOLVE_APPLY_ENABLED="${FACTORY_EVOLVE_APPLY_ENABLED:-1}"
FACTORY_EVOLVE_APPLY_MODEL="${FACTORY_EVOLVE_APPLY_MODEL:-$FACTORY_MODEL_PREMIUM}"
FACTORY_EVOLVE_APPLY_BUDGET="${FACTORY_EVOLVE_APPLY_BUDGET:-3}"
FACTORY_EVOLVE_APPLY_MAX="${FACTORY_EVOLVE_APPLY_MAX:-3}"
FACTORY_EVOLVE_APPLY_DIFF_CAP="${FACTORY_EVOLVE_APPLY_DIFF_CAP:-40}"
FACTORY_BRAIN_REPO="${FACTORY_BRAIN_REPO:-$HOME/path/to/your-memory-repo}"

# --- the trigger (component 2) -----------------------------------------------
# Armed at Phase F (D7: Rick's Mac), never before. install-trigger.sh refuses below
# dial 1 regardless.
FACTORY_INTERVAL_MINUTES="${FACTORY_INTERVAL_MINUTES:-30}"

# THE LAUNCHD JOB'S PROGRAM (macOS only). It must hold Full Disk Access, because TCC
# refuses ~/Documents to background jobs and the denial is a silent exit 126. On this
# Mac the granted binary is the nvm node below (verified in the TCC database and probed
# live, Phase F) — /bin/bash could not be added through the System Settings picker.
# The grant covers the job's children, so one granted program carries the whole tick.
# FRAGILITY, NAMED: this path breaks if nvm upgrades/removes v24.11.0. That break is
# loud, not silent — install-trigger's --verify probes this exact program in a real
# launchd context, and FACTORY.md's idle checklist starts with --status/--verify.
FACTORY_TRIGGER_PROGRAM="${FACTORY_TRIGGER_PROGRAM:-$HOME/.nvm/versions/node/v24.11.0/bin/node}"
FACTORY_TASK_NAME="${FACTORY_TASK_NAME:-dark-factory-$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo factory)")}"

FACTORY_RUNNER="${FACTORY_RUNNER:-factory/run-workflow.sh}"

# --- escalation (FACTORY_RULES.md §11) ---------------------------------------
# THE ONLY THING THAT REACHES RICK: email to owner@example.invalid AND Slack, wired in
# factory/notify-vox.sh (which also appends to a local feed so an offline machine still
# keeps the record). The label + comment on the issue itself remain the durable record;
# the notification is a pointer.
FACTORY_NOTIFY_CMD="${FACTORY_NOTIFY_CMD:-bash factory/notify-vox.sh}"

# Defined ONCE, because more than one script escalates. Never fatal: an escalation whose
# channel is down is still an escalation; the ledger write already happened.
# CONTRACT: the whole message arrives on STDIN; argv[1] is the target, for routing only.
factory_notify() {              # factory_notify <target> <reason...>
  local target="$1"; shift
  if [ -z "${FACTORY_NOTIFY_CMD:-}" ]; then
    echo "NOT NOTIFIED - FACTORY_NOTIFY_CMD unset; this waits in .factory/needs-human.md"
    return 0
  fi
  if printf '%s\n' "$target needs a human: $*" | eval "$FACTORY_NOTIFY_CMD" "$target" \
       >/dev/null 2>&1; then
    echo "NOTIFIED via FACTORY_NOTIFY_CMD"
  else
    echo "NOTIFY_FAILED - the escalation is recorded in .factory/needs-human.md"
  fi
}

# --- paths -------------------------------------------------------------------
# The holdout: assertions the builder is blocked from READING, not merely from editing
# (FACTORY_RULES.md §9, program decision D5: in-repo + tool-deny). Enforced with the
# agent's own deny list in run-workflow.sh, because a sentence in a prompt is not
# enforcement.
FACTORY_HOLDOUT_DIR="${FACTORY_HOLDOUT_DIR:-.factory/holdout}"

# Never-committed files, asserted gitignored before any workflow that commits
# (FACTORY_RULES.md §5a). Standing facts: RESEND_API_KEY is the full-access key; the
# APNs .p8 is the secret; service-role keys never leave vault/env.
FACTORY_SECRET_FILES="${FACTORY_SECRET_FILES:-.env .env.local supabase/functions/.env credentials.json service-account.json}"

# --- EXPORT, or half of the above is decoration --------------------------------
# guard.py reads the caps and the base branch from the PROCESS ENVIRONMENT; sourcing
# this file sets shell variables only. Exported BY NAME so a forgotten one is a visible
# omission rather than a silent one.
export FACTORY_AGENT \
       FACTORY_AUTONOMY \
       FACTORY_BACKEND \
       FACTORY_BASE_BRANCH \
       FACTORY_BRAIN_REPO \
       FACTORY_DB_FLOOR_SCHEMAS \
       FACTORY_DB_HOT_TABLES \
       FACTORY_DB_JUDGE_BUDGET \
       FACTORY_DB_JUDGE_MODEL \
       FACTORY_DB_PROTECTED_SCHEMAS \
       FACTORY_DB_PROTECTED_TABLES \
       FACTORY_EVOLVE_BUDGET \
       FACTORY_EVOLVE_MODEL \
       FACTORY_EVOLVE_APPLY_ENABLED \
       FACTORY_EVOLVE_APPLY_MODEL \
       FACTORY_EVOLVE_APPLY_BUDGET \
       FACTORY_EVOLVE_APPLY_MAX \
       FACTORY_EVOLVE_APPLY_DIFF_CAP \
       FACTORY_DEPLOY_EXCLUDE \
       FACTORY_DEPLOY_PROJECT_REF \
       FACTORY_EF_BASE_URL \
       FACTORY_E2E_FLOOR_FILE \
       FACTORY_E2E_FLOOR_KEY \
       FACTORY_FILE_CAP \
       FACTORY_HEALTH_CMD \
       FACTORY_HEALTH_MARKERS \
       FACTORY_HOLDOUT_DIR \
       FACTORY_INTERVAL_MINUTES \
       FACTORY_LOCK_GRACE_MINUTES \
       FACTORY_LOCK_STALE_MINUTES \
       FACTORY_MAX_BUDGET_USD \
       FACTORY_MAX_FIX_ATTEMPTS \
       FACTORY_MAX_PARALLEL \
       FACTORY_MODEL_CHEAP \
       FACTORY_MODEL_PREMIUM \
       FACTORY_NOTIFY_CMD \
       FACTORY_REQUIRED_MARKERS \
       FACTORY_RUNNER \
       FACTORY_SECRET_FILES \
       FACTORY_SIZE_CAP \
       FACTORY_STOP_FILE \
       FACTORY_STOP_LABEL \
       FACTORY_TASK_NAME \
       FACTORY_TRIGGER_PROGRAM \
       FACTORY_VALIDATE_CMD \
       FACTORY_VALIDATE_QUICK \
       FACTORY_WORKTREE_LINKS
