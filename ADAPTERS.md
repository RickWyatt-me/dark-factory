# ADAPTERS — what is source-project-shaped and what swapping it takes

This export is a **faithful extraction** of a working factory (source: a
Supabase + Expo/React-Native product repo). v1 documents the seams instead of
speculatively rewriting them. Every file below ships as extracted (modulo the
identifier scrub recorded in `scripts/sync-from-source.sh`); this file is the
honest map of what runs anywhere, what is configured, and what an importing
project must replace.

Portability classes, from the pinned-commit dependency trace:

- **GENERIC** — runs as-is in any repo.
- **CONFIG** — parameterized; re-point values, don't edit logic.
- **ADAPTER** — shaped around the source stack; keep the contract, replace the
  implementation (or disable the optional road it serves).
- **STATE** — runtime; ships empty (see `.factory/`).

## The four load-bearing contracts (keep these when you swap anything)

1. **Gate contract** — the validate command prints positive markers with
   counts; "empty is not pass"; `--prove` must show the gate can fail;
   conditional rungs always print a conclusion (`*_NONE` or `*_OK`).
2. **Deploy contract** — pointer-based (`.factory/deploy/CURRENT`), refuses
   what it can't verify, positive post-deploy verification, auto-rollback,
   the pointer never advances past an unverified deploy.
3. **State contract** — labels are the state machine (`factory:*`,
   `priority:*`); transitions only through `factory/state.py`; the stop
   button fails closed.
4. **Notify contract** — `factory_notify` never fails the caller; local feed
   always written before any network channel.

## Coupled vocabularies — move in lockstep or the gate silently degrades

- `FACTORY_REQUIRED_MARKERS` (config.sh) ↔ markers `harness/ci.py` prints ↔
  `factory/gate.sh` conditional greps.
- run-workflow.sh's prompt-placeholder sed set ↔ `RENDER_SET` in
  `factory/evolve_apply_policy.py`.
- `gh_backend.LABEL_FOR_STATE` ↔ `factory/init-labels.sh` table
  (self-asserted by init-labels' drift guard).
- merge.sh's squash trailer `Issue: gh:issue:N` ↔ the `--grep` join in
  `factory/evolve.sh` and `factory/brain-seed.sh`.

## File-by-file

### GENERIC (copy, don't touch)

`factory/tick.mjs` (exists for macOS TCC; harmless elsewhere),
`factory/orchestrator.sh`, `factory/state.py`, `factory/gh_backend.py`,
`factory/init-labels.sh`, `factory/gate.sh`, `factory/cost.py`,
`factory/node_failure.py` (tied to the Claude Code JSON envelope),
`factory/tripwire.py` (`.claude/*` artifact patterns — Claude-Code-shaped),
`factory/evolve.sh`, `factory/evolve-apply.sh`,
`factory/evolve_apply_policy.py`, `factory/merge.sh` (one seam: the BMAD
commit-trailer block `Epic/Story/Type/Learning/Affected` — the source repo's
commit convention, also echoed in run-workflow.sh, evolve-apply.sh and
`prompts/implement.md`; replace consistently with your own or strip),
`factory/run-workflow.sh` (two documented seams: the agent-CLI flag contract —
`claude -p --model --allowedTools … --output-format json` — and the three
governance filenames MISSION.md / FACTORY_RULES.md / CLAUDE.md),
`factory/prompts/fix.md`, `factory/evolve-prompts/*`,
`factory/evolve-apply-prompts/*`, `harness/mutations/run.py` (mechanism only —
its data file is an ADAPTER).

### CONFIG (re-point, keep logic)

- **`factory/config.sh`** — THE binding surface. Everything project-specific
  belongs here; if you're editing another script to change a path, that's a
  bug. Re-point: agent/models/budgets, `FACTORY_VALIDATE_CMD`/`_QUICK`,
  `FACTORY_REQUIRED_MARKERS`, base branch (`develop` today), deploy block,
  DB table/schema lists, notify command, trigger program
  (`FACTORY_TRIGGER_PROGRAM` — the source machine pinned an FDA-granted nvm
  node at `~/.nvm/versions/node/v24.11.0/bin/node`; yours differs), brain
  repo (optional), TF road (off by default).
- **`factory/install-trigger.sh`** — plist/cron/schtasks machinery is
  generic; re-point the verified-binary roster (`supabase claude deno` are
  stack-specific), the label prefix, and the notify checks. The PATH doctrine
  (plist-pinned PATH; launchd strips the environment) is load-bearing on
  macOS, as is `AbandonProcessGroup`.
- **`factory/db_apply_policy.py`** — env-parameterized
  (`FACTORY_DB_HOT_TABLES` / `_PROTECTED_SCHEMAS` / `_PROTECTED_TABLES` /
  `_FLOOR_SCHEMAS`); one in-code value: the allowed function-schema whitelist
  (`vox`/`public`) around lines 279/332. Roles `authenticated`/`service_role`
  are the Supabase role model.
- **`harness/harness.config.json`** — the intended per-project swap point for
  gate commands, count regexes, timeouts, app wiring. Every `npm run …`
  command, the health function name, and the dotenv key list are the source
  project's.
- **`factory/guard.py`** — mechanism generic; the PROTECTED list is your
  project's constitution and is deliberately kept in code: porting means a
  human rewriting that list (governance files stay; source-repo rows like the
  Stripe function paths, `docs/factory/vox.prd.md`, `.agents/harness/*`,
  `supabase/seed.sql` go).

### ADAPTER (replace the implementation, keep the contract)

| File | Shaped around | Swap means |
|---|---|---|
| `factory/deploy.sh` | Supabase Edge Functions (`supabase functions deploy`, `fn-*` naming, EF boot codes incl. 546, config.toml refusal) | Rewrite for your deploy target keeping the deploy contract above. |
| `factory/db-apply.sh` | Supabase Management API (`api.supabase.com/v1/projects/…`), macOS keychain token, `supabase_migrations.schema_migrations` | Optional road — a project without it keeps prod DB apply human. The three-rung structure (static policy → independent judge → human floor) is the exportable idea. |
| `factory/db-apply-prompts/judge.md` | Source project's DBA scar corpus + skill pointer | Rewrite the scar corpus from your own history; keep park-by-default + read-only `verify_sql` contract. |
| `factory/notify-vox.sh` | Resend email + Slack webhook; VOX-shaped filename (rename upstream someday, not here) | The designated notify seam — any script honoring the notify contract; wire via `FACTORY_NOTIFY_CMD`. |
| `factory/tf-build.sh` | Expo prebuild + xcodebuild + App Store Connect (ASC ids are scrubbed placeholders; helper scripts `scripts/install-prebuilt-dsyms.sh`, `scripts/testflight-set-test-notes.py` are NOT in this export) | Optional road, `FACTORY_TF_ENABLED=0` default. Keep pointer/coalescing/non-gating if you build an artifact road. |
| `factory/brain-seed.sh` | Owner's personal memory repo + `projects/vox/...` ledger path | Optional; swap the target repo/path or leave unwired. Fact-only, git-derived — keep that. |
| `factory/prompts/prime.md, plan.md, implement.md, review.md, judge.md, triage.md, assumptions-judge.md` | Source repo's territory, conventions, invariants, scope areas | Rewrite content per project. PRESERVE the machinery contracts: review.md's PR front-matter block, judge/assumptions-judge verdict JSON schemas, plan.md's ASSUMPTIONS/ESCALATE/FOLLOWUP grammar, triage.md's `triage.json` shape. |
| `harness/ci.py` | Family roster + shell-outs (`supabase db reset`, `npx expo prebuild`, `xcodebuild -workspace ios/VOX.xcworkspace`) | The ladder/marker/floor/STOP/`--prove` mechanics are the exportable spec; the families are yours to define. |
| `harness/appproc.py` | Local Supabase stack (`supabase start/status`, vault seed via psql, `host.docker.internal`, key-name pairs) | The "reach the software under test" seam — rewrite per stack. |
| `harness/e2e.py` | The product's two user journeys, its schema, its fixture tokens, `delivered@resend.dev` sink | Entirely product-shaped; the per-step counted-assertion doctrine is the template. |
| `harness/migration_lint.py` | `supabase/migrations/` `00NNN` convention + generated index | Keep append-only + conclusion-marker mechanics; re-encode your convention. |
| `harness/drizzle_lint.py` | Source repo's client-DB chain (`src/db/migrations` triple artifact) | Only if you have a second migration chain; otherwise leave dark (`DRIZZLE_LINT_NONE` path). |
| `harness/mutations/defects.json` | 8 defects seeded from the source product's real escaped bugs, anchored to its files | MUST be re-seeded from your own escaped-bug corpus — mutation proof over someone else's bugs proves nothing. |
| `harness/fixtures/pipeline-audio.m4a` (+README) | Spoken ground truth for the source E2E | Regenerate per product (README carries the `say`/`afconvert` recipe — macOS). |

### Known dangling references (deliberate, v1)

The engine ships as extracted, so some scripts/prompts reference source-repo
paths that don't exist in an importing repo until bound or rewritten:
`docs/factory/vox.prd.md` (guard.py protected row; plan.md),
`.claude/skills/vox-database-migrations/SKILL.md` (db-apply judge + notify
text), `_bmad-output/project-context.md` + `_bmad/_memory/platform-bulletin.md`
(prime.md, config.sh worktree links), `scripts/gen-migrations-index.mjs` +
`MIGRATIONS.md` (migration_lint), the two tf-build helper scripts,
`.agents/harness/*` rows in guard.py (the source repo's frozen predecessor),
and `docs/factory/phase-b-validation-harness.md` (harness/README.md — the
source's design doc for the gate). Binding (INSTALL.md) tells you which to
satisfy, stub, or strip per project.

Two more source-shaped residues, documented rather than rewritten (the
no-renames rule): default runtime homes named `~/.vox-factory/` appear in
tf-build.sh's build-dir default and in comments (run-workflow.sh,
brain-seed.sh) — an importing project overrides via `FACTORY_TF_BUILD_DIR`
and its own symlink targets; and the engine's comments cite the source
project's owner by first name and by dated directives — they are history,
not instructions to an importer.

### macOS-isms

`security` keychain (db-apply, notify, install-trigger verify), launchd/TCC
(FDA attaches to the trigger's program binary — the reason tick.mjs exists),
BSD `sed -i ''` (tf-build), `say`/`afconvert` (fixture recipe). Linux gets
cron via install-trigger; the keychain lookups need a secret-store equivalent.
