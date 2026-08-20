<!--
  VOX dark factory — implement node. Rewritten from the piv-implement skill
  (dark-factory program Phase C, dossier 04 §1). Executes the plan task-by-task with
  validation at every step; the commit itself is made by the runner, not by you.
-->

# Node 3: implement

Execute `{{rundir}}/plan.md` against `{{issue}}`, task by task, in order, running each
task's VALIDATE command as you go. Read the ENTIRE plan first.

Ground rules for this node's tools (Phase D lap 1, patch 3):

- The issue is FULLY materialized at the path given as `{{issue}}` — read that file.
  `gh` is not in your toolset; never invoke it.
- Your Bash allowlist rejects compound diagnostic one-liners; run simple single
  commands instead of chained `cat`/`ls`/`cd` pipelines.

## Absolute prohibitions (FACTORY_RULES.md §2)

1. **Never modify a test, assertion, tolerance, or fixture to make something pass.**
   Fix the source. If a check is genuinely wrong, say so in the report and stop — that
   is a needs-human escalation, not a change you make.
2. **Never touch a protected file** (§5): governance, `factory/**`, `harness/**`,
   `.factory/locks/**`, `.factory/holdout/**`, the frozen `.agents/harness/**`,
   existing migrations, `supabase/seed.sql`, `.github/**`, env/secret-shaped files,
   the Stripe surfaces, `_shared/auth*`, `function-allowlist.json`.
3. **Never touch the production database, never deploy an Edge Function, never push.**
   A schema change is a new sequential local migration file per the plan; applying it
   anywhere is not your step.
4. **Never send anything outside the building**: no email to real recipients, no push
   notifications, no external webhooks. Tests use fixtures and local sinks.
5. **Never add a dependency** without the plan calling for it and the report justifying
   it.
6. **Never build beyond what the plan asked.** No opportunistic refactors, no "while I
   was in here". The plan's non-goals section is binding.
7. **Stay under 500 changed lines / 12 files.** Over the cap, stop and report — the
   work needs splitting.

## VOX conventions that bite (CLAUDE.md is the full list)

- Strict TypeScript: no `any`, no `@ts-ignore`. Imports via `@/` aliases, never deep
  relative paths.
- snake_case ↔ camelCase conversion happens in the repository layer ONLY. Explicit
  `null` (never `undefined`) for DB-nullable. Dates: timestamptz UTC in DB, ISO 8601 in
  API.
- Edge Functions return `{ data, error }`; typed domain errors in services; kebab-case
  EF directories (`fn-name`); shared code in `supabase/functions/_shared/`.
- New network/EF hooks use `AsyncState<T>`; do NOT copy the older isLoading-boolean
  hooks. Local Drizzle reads use `useLiveQuery`.
- The recording queue-state chain in CLAUDE.md is law — no skipping states.
- Tests are part of the change: a bug fix includes a regression test that fails on the
  base branch; tests live in the normal test directories, never in `harness/**`.

## Validate as you go

After each task, run **exactly this command, verbatim**:

```
{{quick}}
```

It is the only test command on your allowlist (plus `python3 -c` for measurements); any
other way of running the tests is denied. This includes a `--quick` failure on a file
your task never touched: do not re-run it in isolation to check for flakiness
(`npx jest ...` and equivalents are not on your allowlist and will be denied) —
document it in `TRAILERS`' `Learning:` line and in `report.md` and move on, per
prohibition §1. **Do not run the full gate** — it belongs to
the independent validator. A builder that can iterate against the gate it is judged by
diverges from the problem exactly when it matters.

## Write `{{rundir}}/TRAILERS`

Five lines, exactly these keys — the repo's standing commit convention, which the runner
puts on the commit (FACTORY_RULES.md §2):

```
Epic: <the epic or roadmap area this serves, or "factory">
Story: <the issue reference — for this run, {{issue_id}}>
Type: <feat | fix | test | docs | refactor | perf>
Learning: <one line worth keeping, or "none">
Affected: <comma-separated top-level areas touched>
```

## Report

Write `{{rundir}}/report.md`: what was built, tasks completed, tests added, validation
results with counts, **deviations from the plan and why** (a documented deviation is a
decision; an undocumented one is a bug), and any issues encountered. Leave the worktree
clean of scratch files — everything you produced is either the change itself or lives
in `{{rundir}}/`.

## Before you summarize

After writing `{{rundir}}/TRAILERS` and `{{rundir}}/report.md`, confirm both actually
landed — Read each one back. Do not state either file was written in your final summary
unless that check just showed it on disk. (Evolution rec, lap #8: a node claimed both
were written; neither existed.)
