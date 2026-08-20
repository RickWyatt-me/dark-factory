<!-- TEMPLATE — FACTORY.template.md
     Copy to your repo root as FACTORY.md and fill every {{SLOT}}. This is the
     operator's manual — the file a human reads to run, stop, and diagnose the
     factory. Delete each FILL comment when its slot is filled. -->

# The {{PROJECT_NAME}} Dark Factory — operator's guide

<!-- Owner: humans only. This is the front door for OPERATING the factory. -->

Work arrives as a GitHub issue. Validated code merges to `{{INTEGRATION_BRANCH}}` and
deploys, health-checked, with nobody at the keyboard. What the product is and is never:
[`MISSION.md`](MISSION.md). How the factory must behave:
[`FACTORY_RULES.md`](FACTORY_RULES.md).

## How work moves

```
issue → factory:accepted → implement (branch + PR) → validate (full gate + judge)
      → factory:approved → squash-merge to {{INTEGRATION_BRANCH}} → factory/deploy.sh ships
```

The labels are the audit trail and are phone-editable. `factory:needs-human` is the
only state that reaches the owner ({{NOTIFY_CHANNELS}}, via `factory/notify-vox.sh` —
a source-project-shaped filename slated for an upstream rename; it is the engine's
notify entrypoint); everything else is the machine talking to itself.

## The dial (`FACTORY_AUTONOMY` in `factory/config.sh` — human commits only)

| Dial | The trigger's tick may… |
|---|---|
| 0 | nothing — every workflow is run by hand |
| 1 | implement accepted issues (branch + PR opens, then waits) |
| 2 | + validate PRs and record verdicts (merge still waits for a human) |
| 3 | + auto-merge green PRs to {{INTEGRATION_BRANCH}}, then run `factory/deploy.sh` |

A new installation starts at dial 0 and signing `factory:accepted` is a human keystroke
(FACTORY_RULES §1). Before ANY notch up: `python3 harness/ci.py --prove` must pass (the
gate re-proves it can fail), and the notch itself is the owner's explicit go, one notch
at a time, never a batch.

## The trigger

A scheduler on the factory machine. It POLLS: a timer fires `factory/orchestrator.sh`
every {{TICK_MINUTES}} minutes, which dispatches at most what the dial allows. Nothing
pushes; filing an issue at 09:01 waits for the next tick.

```
bash factory/install-trigger.sh --status    what is armed, dial, stop state
bash factory/install-trigger.sh --verify    prove the job's environment works
bash factory/install-trigger.sh --install   arm (refuses below dial 1)
bash factory/install-trigger.sh --remove    disarm
```

`install-trigger.sh` implements a macOS launchd LaunchAgent; on another OS this
script is the porting seam (see ADAPTERS.md in the engine repo) — the polling
contract above is what any port must preserve.

## The stop button — two, on purpose, both tested live

- `touch .factory/STOP` — works with the network down, checked before anything
  else on every tick (the gate checks it too, before any rung).
- Label any **open** issue `factory:stop` — works from a phone, **fails closed**:
  if the stop state cannot be read, nothing dispatches.

## When it looks idle, check in this order

An unattended factory that died looks identical to one with nothing to do. Loud
checks first:

1. `bash factory/install-trigger.sh --status` — armed? dial? STOP file present?
2. `factory-orchestrator.log` — is the timestamp of the last tick recent? A log
   that stopped growing means the scheduler stopped, not the work.
3. `bash factory/install-trigger.sh --verify` — a moved binary or an expired
   `gh` token makes every tick read as "stopped" (fail-closed) with no error.
4. `.factory/needs-human.md` + `.factory/notifications/feed.log` — anything parked?
5. **You are logged out.** A per-user scheduled job runs only in the owner's login
   session (true of macOS LaunchAgents; check your scheduler's equivalent). A
   factory quiet since the last logout is off, not idle.
6. Your interactive dev stack was up — the gate refuses to share the local
   stack's ports/gateway (by design) and parks the PR `needs-human`. Touch
   `.factory/STOP` before dev sessions to keep the tick from colliding at all.

## Territory — what the factory owns

<!-- FILL: Enumerate the surfaces the factory owns, the gate rung that verifies
     each, and what stays human, always. This section restates MISSION's "Core
     capabilities" + "does NOT own" in operator shorthand. -->

{{TERRITORY_SUMMARY}}

<!-- OPTIONAL — delete if not used. An artifact-build road out (FACTORY_RULES
     §2.11): internal-track builds cut from merged work on idle ticks, feeding a
     human manual-test queue. The engine's worked example is factory/tf-build.sh
     (pointer at .factory/testflight/CURRENT, labels ranges factory:needs-mt,
     appends the MT queue, kill switch FACTORY_TF_ENABLED=0). Non-gating by
     construction: failure notifies and the pointer stays. -->

## Deploys

`factory/deploy.sh` is the only road out (FACTORY_RULES §2.5): it ships merged
`{{INTEGRATION_BRANCH}}` only, refuses ranges containing migrations or
deployment-config changes, skips {{PAYMENT_SURFACES_SHORT}} and first-time deploys,
health-checks with positive markers, and auto-rolls-back. The trigger runs it **only at
dial 3** (after each auto-merge, plus an idle-tick catch-up); at dial 0–2 a human types
it. Full map: [`docs/factory/deploy-map.md`](docs/factory/deploy-map.md).

<!-- OPTIONAL — delete if the §2.4a prod-DB road is not enabled. -->
## Migration laps

Pre-merge, the gate's `migrations` family makes schema changes safe:
`harness/migration_lint.py` enforces the repo's migration procedure (append-only,
strictly sequential, the required header, the regenerated index), then a local replay
so integration/E2E run against the schema the PR ships. At deploy the range moves
**DB first, code second** through `factory/db-apply.sh` under the §2.4a review chain
(static allowlist → independent migration judge → the human floor), with evidence
under `.factory/deploy/db-apply/`. What always parks for you — **the human floor**:
statements that destroy stored data (TRUNCATE, DROP TABLE/COLUMN, DELETE) and
statements targeting the {{HUMAN_FLOOR_SCHEMAS}} schemas — plus anything the judge
parks. A parked range notifies with the files, the classes, and the procedure
pointer; you apply by hand + verify, then re-run `factory/deploy.sh` (or let the next
tick's catch-up retry it). A failed apply or probe stops the run with the SQL error
and the evidence path, and never auto-rolls-back DDL; the deploy pointer never
advances past an unverified apply. Full map:
[`docs/factory/prod-db-apply.md`](docs/factory/prod-db-apply.md).

## After a lap — the evolution loop

Neither step gates anything or sits in a lap's critical path.

- `bash factory/evolve.sh --catch-up` — for every DECIDED lap (merged, or parked
  needs-human) not yet reviewed, one cheap capped agent session reviews the lap's
  **process** from its run artifacts — never the merged code — and writes
  `.factory/evolution/issue-N/evolution.md` plus proposals in
  **`.factory/evolution/RECOMMENDATIONS.md`**. That ledger is the reading list:
  every block is ready-to-apply text, and **applying one is always a human commit**
  — the factory may not edit the rules it is judged by, and the session's Write
  allowlist covers `.factory/evolution/` and nothing else.

<!-- OPTIONAL — delete if you have no external memory/log repo. The engine ships
     factory/brain-seed.sh, a fact-only lap-record seeder that appends each
     merged lap's sha/files/gate counts/deploy state/cost to a separate records
     repo and commits there. Every field is derived from git and run artifacts,
     never from claims. Source-project-shaped: expects the source project's
     records repo layout — adapt before use (see ADAPTERS.md). -->

Both are idempotent and safe to re-run; both check `.factory/STOP` first and touch
nothing the GitHub API serves, so they work with the network down or the rate limit
exhausted. **At dial 3 the tick runs the catch-ups itself** — after each auto-merge,
on idle ticks, and on held ticks — so the hand-run form is a convenience, not a duty.

## Maintenance cadence (periodic, not per-lap)

Roughly monthly, or when the queue is quiet — all advisory, nothing auto-applies:

1. Read `.factory/evolution/RECOMMENDATIONS.md`; apply or strike each open block.
2. `bash factory/evolve.sh --window 30` — the proactive scan: what recurs across
   laps (repeated assumptions, repeated denials, cost drift, human toil) and what
   it should become.
3. `python3 factory/cost.py report` — read the trend, not just the total; a node
   whose spend grows lap over lap is a process finding.
4. Audit the governance files against the merged range since the last check —
   wrong rules mislead every future lap.

On a model upgrade (a new default model in `factory/config.sh`): re-test the prompt
layer against a real task before trusting old prompt scar tissue — model upgrades
quietly retire instructions, and dead rules compete for attention with live ones.

## Standing caveats (each presents as "it stopped and there is no error")

- **GitHub does not fire `on: push` workflows for commits made with the default
  `GITHUB_TOKEN`.** If the factory's pushes ride a user OAuth token, CI fires; **if a
  deploy ever moves into GitHub Actions, redo the token analysis from scratch.**
- **Scheduled GitHub workflows only run from the default branch.** A cron on a
  feature branch does nothing, forever, with no warning.
- **On a public repo, GitHub disables scheduled workflows after 60 days of repo
  inactivity** — quiet gets switched off for being quiet. The rule starts to matter
  the day a private repo goes public.
- **"Deferred" on the GitHub backend means CLOSED-as-not-planned + the label.** An
  OPEN issue carrying only `factory:deferred` still reads as untriaged, holds the
  queue at dial 3, and starves the idle catch-up. To defer: close the issue as
  not-planned AND label it.
- **STOP blocks `--prove` too** — ci.py checks `.factory/STOP` before every rung,
  prove included, so "touch STOP while you prove" cannot work. The sanctioned
  quiet window is `install-trigger.sh --remove` → prove → `--install` (which
  re-runs `--verify`). This is deliberate: the stop button has no exceptions.

## Machine environment (per-install, not per-project)

Facts about the machine that ticks, not about the product. Each item shows what the
source installation used as a worked example; record your own beside it.

| Item | Source installation (worked example) | This installation |
|---|---|---|
| Scheduler | macOS launchd LaunchAgent, plist-pinned PATH, `launchctl kickstart gui/$UID/<label>` to force a tick | {{SCHEDULER}} |
| Scheduler PATH doctrine | launchd strips PATH; the plist pins the verified PATH; `--install` refuses until `--verify` passes; re-run `--verify` if any binary moves | {{PATH_DOCTRINE}} |
| GitHub auth | `gh` CLI with the owner's user OAuth (keyring); an expired token reads as "stopped" with no error — record the expiry date | {{GH_AUTH}} |
| DB-apply credential | a keychain item read at apply time (only if the §2.4a road is enabled) | {{DB_APPLY_CREDENTIAL}} |
| Notify channel | `FACTORY_NOTIFY_CMD` wired to email + a chat webhook stored outside the repo; tested on purpose, once, dated | {{NOTIFY_WIRING}} |
| Runtimes | python ≥ 3.10 (with a `python` → `python3` shim), node on a stable path, the coding agent CLI authenticated | {{RUNTIMES}} |
| Sync-service shield | repo in a cloud-synced folder → gitdir relocated outside it (`git init --separate-git-dir`), runs/worktrees symlinked to an unsynced dir | {{SYNC_SHIELD}} |
| Login-session dependency | LaunchAgents run only while the owner is logged in | {{LOGIN_SESSION}} |
