# INSTALL — binding the dark factory to a project

This is the reference for importing this repo's engine into a project and
arming it. The `skills/dark-factory-import` skill walks the same procedure
interactively with its refusal gates enforced; this document is the facts.
The dividing line: decisions, refusals, and human-approval gates live in the
skill; machinery facts live here.

Nothing below runs in THIS repo. Every step happens in the importing
project's repo, on the machine that will tick.

## Phase 0 — Prerequisites and refusals

Refuse to proceed without ALL of:

- **A PRD** with non-goals. No PRD means no out-of-scope list, which means
  triage cannot reject, which means scope rot with nobody watching.
- **Observable software**: an app the gate can start and probe, or a
  walking-skeleton plan that produces one before the first factory lap.
- **A real test command** that fails when the product is broken.
- **A human owner** who will fill the governance templates, sign
  `factory:accepted`, and hold the dial.

Machine audit (record what you find; credential expiry dates too):

- `gh auth status` — the dispatcher, gate, and merge all shell to `gh`; an
  expired token reads as "the factory stopped".
- `python3 --version` ≥ 3.10, with a `python` shim if any tooling expects it.
- `node` on a stable absolute path (the trigger pins it; version-manager
  paths break on upgrade — see `FACTORY_TRIGGER_PROGRAM` below).
- The coding agent CLI (`claude`) authenticated, on PATH.
- A machine that stays on and logged in (a macOS LaunchAgent runs only in
  the owner's login session).

**Cloud-synced folder shield (decide now, not after the first broken lap):**
if the repo lives under iCloud/Dropbox/OneDrive, move the gitdir out
(`git init --separate-git-dir ~/.PROJECT-git`) and plan `.factory/runs/` and
`.worktrees/` as symlinks into an unsynced home (`~/.PROJECT-factory/`).
The source factory lost a lap to a sync conflict-copy inside `.git` and a
file-storm that took down a mid-gate dev server.

## Phase 1 — Engine copy

From this repo, copy **byte-identical** into the project:

```
factory/            # the whole engine
harness/            # the gate plumbing (its families get rewritten in Phase 4)
```

Verify: `diff -r` between this repo and the copy — zero differences.
The source of truth for what version you copied is this repo's `ENGINE_PIN`.

Then scaffold state and ignores:

- Copy `.factory/` (the scaffolding shipped here — READMEs, empty dirs,
  emptied `locks/floor.json`).
- Append `templates/gitignore.snippet` to the project's `.gitignore`.
- Run `git check-ignore -v` on every secret-bearing file
  (`FACTORY_SECRET_FILES` once config exists) — empty output on any of them
  means STOP before anything can commit.

## Phase 2 — Governance fill-in (human commits, always)

Fill from `templates/`: `MISSION.template.md` → `MISSION.md`,
`FACTORY_RULES.template.md` → `FACTORY_RULES.md`,
`FACTORY.template.md` → `FACTORY.md`, and merge `CLAUDE.template.md`'s
factory-governance block into the project's `CLAUDE.md`.

Rules that are not negotiable:

- Section headings and §-numbers are **load-bearing** — engine prompts and
  scripts cite them (`§2.5`, `§7.3`, "MISSION Gate 3"). Fill content; never
  rename or renumber.
- Every filled file is a **human commit** and goes straight onto the
  protected list. No agent may edit the rules it is judged by.
- Conservative defaults ship in the templates: dial 0, human signs
  `factory:accepted`, no prod-DB road (§2.4a optional), evolution auto-apply
  OFF (§9b), no artifact-build road (§2.11 optional). Each is enabled later
  by its own human commit, one at a time.
- Before leaving Phase 2: `grep -rn '{{' MISSION.md FACTORY_RULES.md
  FACTORY.md CLAUDE.md` must return nothing. (`{{…}}` is also the runner's
  live render syntax — a leaked template token inside `factory/prompts/*.md`
  is a runner-breaking bug, so never paste template text there.)

## Phase 3 — Config binding

Author `factory/config.sh` **fresh against the copied file as its own
annotated template — never copy-edit another project's values.** Every
project-specific value lives in config.sh; editing any other script to
change a path is a bug. The main knobs (full inventory in the file itself):

| Knob | Meaning |
|---|---|
| `FACTORY_AGENT`, `FACTORY_MODEL_PREMIUM/_CHEAP`, `FACTORY_MAX_BUDGET_USD` | agent CLI + model routing + per-node budget |
| `FACTORY_VALIDATE_CMD` / `FACTORY_VALIDATE_QUICK` | the gate (full ladder / builder's leash) |
| `FACTORY_REQUIRED_MARKERS` | must equal exactly what your gate prints |
| `FACTORY_BASE_BRANCH`, `FACTORY_BACKEND` | integration branch; `github` or `files` |
| `FACTORY_AUTONOMY` | the dial — **starts at 0** |
| `FACTORY_STOP_FILE` / `FACTORY_STOP_LABEL` | both halves of the stop button |
| `FACTORY_SIZE_CAP` / `FACTORY_FILE_CAP` | PR caps (defaults 500 / 12) |
| `FACTORY_WORKTREE_LINKS`, `FACTORY_SECRET_FILES` | env plumbed into worktrees; the never-commit list |
| `FACTORY_DEPLOY_*`, `FACTORY_EF_BASE_URL`, `FACTORY_HEALTH_*` | deploy road — leave unset to keep deploys human |
| `FACTORY_DB_*` | db-apply road lists — only with §2.4a enabled |
| `FACTORY_NOTIFY_CMD` | your notify script (see ADAPTERS: notify seam) |
| `FACTORY_TRIGGER_PROGRAM`, `FACTORY_INTERVAL_MINUTES`, `FACTORY_TASK_NAME` | what the scheduler runs, how often, its label |
| `FACTORY_TF_ENABLED` | artifact-build road — default 0 |
| `FACTORY_BRAIN_REPO` | optional external lap ledger — unset to skip |

Then rewrite `factory/guard.py`'s PROTECTED list for this project (the
mechanism stays; the list is the constitution — governance files, factory/,
harness/, locks, holdout, CI config, secrets, migrations append-only, plus
your product's payment/auth surfaces). This edit is deliberate and in code.

## Phase 4 — Gate binding (the real work)

The factory harness is templatable. **The validation harness is not.**

- `harness/harness.config.json`: replace every family's `run` command, count
  regex, and timeout with your project's. Delete families you don't have;
  their conditional markers (`*_NONE`) keep the gate honest about unchecked
  surfaces.
- `harness/appproc.py`: rewrite the "reach the software under test" layer
  for your stack (it ships Supabase-local-stack-shaped).
- `harness/e2e.py`: write YOUR product's real user journey(s), per-step
  counted assertions, teardown. The shipped file is a worked example.
- `.factory/holdout/`: write `run.py` scenarios **before the first accepted
  issue** (rules in its README). The builder never reads this dir.
- `.factory/locks/floor.json`: seed `exact`/`min` from your own first honest
  green run — by human commit. Shipped empty; an empty floor fails the gate.
- `harness/mutations/defects.json`: re-seed from your own escaped bugs.
  Until then, run `--prove` knowing mutation coverage is not yours.
- `factory/prompts/*.md`: rewrite prime/plan/implement/review/judge/triage
  content for your repo. PRESERVE the machinery contracts (verdict JSON
  schemas, review front-matter, ASSUMPTIONS/ESCALATE grammar, triage.json
  shape) — ADAPTERS.md lists them.
- Prove the gate can fail: break a marker on purpose; `python3 harness/ci.py`
  must go non-zero. Then `--prove` for the mutation pass.

## Phase 5 — Machinery proof

- `factory/init-labels.sh` against the project's GitHub repo (labels are the
  state machine; the built-in drift guard asserts the table matches
  `gh_backend.py`).
- Test the notify channel and BOTH stop-button halves on purpose, once.
  Write the date down.
- One full dry workflow at dial 0 driven by hand (file a trivial real issue,
  run `factory/run-workflow.sh` yourself, watch every node).

## Phase 6 — Arm, then climb

- `factory/install-trigger.sh --verify` must pass before `--install` will
  arm (PATH roster, gh auth, notify, and on macOS the TCC/Full-Disk-Access
  probe — grant FDA to the *program binary* the plist runs).
- Dial climbs **one notch per explicitly-approved watched cycle**, with
  `python3 harness/ci.py --prove` green before every notch. Never a batch.
- Permanently human, from day one, regardless of dial: governance edits,
  prod DB apply (unless/until §2.4a is deliberately enabled), external
  releases, promotion to the known-good branch, evolution-recommendation
  application (§9a).

## Re-syncing the engine from the source repo

Maintainers of THIS repo (not importers): when the source factory lands
machinery changes, run

```
scripts/sync-from-source.sh <source-repo-path> <commit-sha>
```

It re-extracts `factory/` + `harness/` byte-identical, applies the recorded
identifier scrub (failing loudly on any new un-scrubbed identifier), records
the pin + governance-source hashes in `ENGINE_PIN`, and flags which templates
need human re-derivation.
