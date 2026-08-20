# .factory/ — the validator's side of the wall

Everything in this directory belongs to the **validation side** of the dark factory.
`FACTORY_RULES.md` §5 protects `.factory/locks/**` and `.factory/holdout/**`; the
builder-side checks live in `harness/` (also protected — the builder may *read and run*
them, never edit them).

Directories here ship empty; each fills at runtime. Empty is the correct initial
state — the gate's "empty is not pass" law applies to check output, not to this ledger.

## Layout

| Path | What it is | Tracked? | Builder may read? |
|---|---|---|---|
| `decisions.md` | Answered-once decisions ledger (§7.4/§7.5) | yes | yes |
| `holdout/` | Scenarios written before the work, never shown to the builder | yes | **NO — tool-denied** |
| `locks/floor.json` | The ratchet: minimum counts per check family, raised only by human commit | yes | yes (read-only) |
| `assumptions/` | Per-issue assumption records written by implement nodes (§7.1) | yes | yes |
| `followups/` | Sub-issue drafts split out under §2.10's size rule | yes | yes |
| `evolution/` | The evolution loop's proposals ledger (§9a/§9b) | yes | yes |
| `deploy/db-apply/` | Prod-apply evidence (only if the §2.4a road is enabled) | yes | yes |
| `notifications/` | `feed.log` — every notification, appended | yes | yes |
| `runs/` | Per-run artifacts: gate logs, the generated serve env | **no (gitignored)** | no |
| `STOP` | The stop button (see below) | only while stopping | n/a |

## The stop button

Creating a file named `.factory/STOP` (contents optional — a reason line is polite)
halts the factory:

- `harness/ci.py` checks for it **first**, before any rung runs. If present it prints
  `FACTORY_STOPPED` and exits non-zero — no gate can go green while the button is down.
- The dispatcher refuses to start any workflow while the file exists, and the
  `factory:stop` label on the repo is the remote equivalent (per `FACTORY_RULES.md`
  §8) — either one stops the line.

To resume: delete the file (`rm .factory/STOP`). Per §8 the button must be **tested on
purpose** before the autonomy dial ever leaves 0.

## The holdout rules (short version — the long one is in each scenario file)

1. Written **before** the work they judge.
2. **Duplicate, do not import** builder-side helpers (process-driver code excepted).
3. **Compose** features the way a user composes them — feature isolation is the
   dominant real failure, not cheating.
4. Use inputs that appear nowhere else in the repo.

Every node the runner spawns gets `--disallowedTools` covering `.factory/holdout/**`;
this directory is off-limits to any implementing agent by `FACTORY_RULES.md` §5 and §9.
