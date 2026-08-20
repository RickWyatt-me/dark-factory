<!--
  VOX dark factory — prime node. Rewritten from the prime-backend skill for VOX's
  server-side territory (dark-factory program Phase C, dossier 04 §1). The factory's
  territory is Edge Functions, local migrations, services, repositories, and their
  tests — never the React Native device surface.
-->

# Node 1: prime

Build a targeted read of the VOX server-side codebase, scoped to what `{{issue}}`
actually touches. The plan node is the expensive one; feeding it a cold read of the
repository is how a premium model gets spent re-deriving what a cheap one could have
handed it.

Ground rules for this node's tools (Phase D lap 1, patch 3):

- The issue is FULLY materialized at the path given as `{{issue}}` — read that file.
  `gh` is not in your toolset; never invoke it.
- If `_bmad/_memory/platform-bulletin.md` is absent or stale in this worktree, say so
  in one line and continue — its absence is an environment fact, not a blocker.
- Your Bash allowlist matches command PREFIXES, so any chained one-liner (`&&`, `;`,
  pipes into `head`) is denied whole. Run simple single commands (lap 2, finding C).
- Your shell is already `cd`'d into this issue's own worktree before you run — every
  git command in the Read list below works unmodified, bare, with no `-C <path>` and
  no absolute path prefix. `git -C <anything> ls-files` does not match the allowlist's
  `git ls-files` prefix and will be denied even though the plain command would have
  worked. (Evolution rec, lap #15.)

## Read

- `git ls-files`, `git log -10 --oneline`, `git status`
- `MISSION.md`, `CLAUDE.md` (the architecture rules: naming, structure, patterns,
  queue states, migration procedure), `README.md` if present
- `_bmad-output/project-context.md` — the standing pre-work read
- `_bmad/_memory/platform-bulletin.md` — the rolling 14-day platform bulletin. Note any
  breaking change, deprecation, or pricing/limit change relevant to the files this issue
  touches; ignore items older than 14 days.
- The Edge Function(s), `_shared/` modules, services, and repositories the issue names
  or implies — `supabase/functions/fn-*/`, `src/services/`, `src/repositories/`
- The tests nearest the touched code: co-located `__tests__/` for src, and
  `supabase/functions/tests/{unit,integration}/` for EFs
- Recent migrations under `supabase/migrations/` when the issue implies schema —
  `MIGRATIONS.md` carries the next number

## Report to `{{rundir}}/priming.md`

Keep it scannable. Cover:

- **What the issue touches**: the MISSION capability area, and the files
- **Existing patterns to mirror**, with `file:line` — data flow
  (Component → Hook → Service → Repository → Supabase), the snake_case↔camelCase
  boundary in the repository layer, `{ data, error }` EF returns, typed domain errors,
  explicit null for DB-nullable
- **The EF invocation contract** for any touched function: how it is triggered (http,
  pg_net chain, pg_cron), what it reads from vault/env, what it writes
- **Pipeline position** when the issue touches the recording pipeline: the queue-state
  chain in CLAUDE.md is law — no skipping states
- **Tests nearby**: which suites cover this area today, and the command families that
  run them
- **Platform-bulletin items** relevant to the touched files, if any
- **Anything that looks already broken** in the area, distinct from the issue. Do not
  fix it. Name it, and note whether it is worth a separate issue.

You are read-only. If you find yourself wanting to edit something, that is a finding for
the report, not an action.
