# dark-factory

A GitHub issue goes in; validated, merged, deployed code comes out — with
nobody at the keyboard. This repo is a standalone export of a **working dark
factory**: the unsupervised build loop that runs a real production app today,
packaged as engine + templates + binding procedure. It builds nothing by
itself — a factory only exists once this engine is bound to a project: its
own MISSION, its own gates, its own protected list, its own human.

What keeps it honest is five restraints, all of which fail closed:

- a **marker-verified validation ladder** — checks prove they ran by emitting
  counted markers, so a silently skipped check reads as a failure;
- a **protected-files guard** — no agent may edit the rules it is judged by,
  the governance files, or the engine itself;
- **independent judge agents** that see the diff and the contract, never the
  builder's notes — they can add reasons to block, never remove one;
- a **graduated autonomy dial** — every notch from "human signs everything"
  to "hands off" is a separate, explicit human decision;
- a **stop button** (`.factory/STOP` + a repo label) checked before any gate
  can go green.

## Lineage

This factory did not start from zero. The foundation — a label-driven state
machine living entirely on GitHub issues, a dumb dispatcher on a timer that
never asks a model what to run, and the `MISSION.md` / `FACTORY_RULES.md` /
`CLAUDE.md` governance trio no agent may touch — comes from
[Cole Medin](https://github.com/coleam00)'s
[dark-factory-experiment](https://github.com/coleam00/dark-factory-experiment).
(The term itself traces through Dan Shapiro's "dark factory" framing, after
FANUC's lights-out plants where robots build robots.) Study his repo too; it
is the clearest statement of the core idea.

What changed here, built on that foundation:

- **No workflow engine.** The original stitches coding sessions together with
  Archon workflows on a VPS cron. This one is Claude Code alone — a shell
  orchestrator and runner, triggered by a macOS launchd job in the owner's
  login session. Fewer moving parts, one machine, fail-closed when logged out.
- **A brain.** Persistent cross-session memory in a separate git repo —
  identity, locked decisions, project state — plus `brain-seed.sh`, which
  writes each lap's record derived from git, never from an agent's claims.
  Agents never relearn. (The pattern is published as a starter:
  [brain-starter](https://github.com/RickWyatt-me/brain-starter).)
- **A graduated dial instead of a fixed autonomy level.** 0–3, every notch a
  separate explicit human go — and before any notch, `harness/ci.py --prove`
  must re-prove the gate can still fail. A gate that cannot fail is not a gate.
- **A marker-verified ladder with mutation proof.** Checks emit counted
  markers so a silent skip reads as a failure, and the gate is periodically
  proven against seeded defects, not assumed.
- **Two stop buttons, both fail closed.** A file on disk that works with the
  network down, and a phone-editable label; if the stop state cannot be read,
  nothing dispatches.
- **A production-database road.** `db-apply.sh` applies merged migrations to
  prod unattended through three rungs: a static DDL policy, an independent
  migration judge, and post-apply probes that verify the schema actually moved.
- **An artifact road.** Internal TestFlight builds for a native mobile app —
  the factory's output isn't only merged code.
- **An evolution loop that proposes but does not apply** — recommendations
  land as documents for a human, with one narrow, judged, kill-switched
  auto-apply channel for prompt edits only.
- **Escalation that cannot fail.** Local feed → email → Slack, in that order;
  a dead webhook degrades to a log line, never to an error, and only
  "needs a human" ever reaches a phone.

## Get it

```bash
git clone https://github.com/RickWyatt-me/dark-factory.git
```

Install the import skill for [Claude Code](https://claude.com/claude-code)
(it walks the binding procedure with its refusal gates enforced):

```bash
mkdir -p ~/.claude/skills
ln -s "$(pwd)/dark-factory/skills/dark-factory-import" ~/.claude/skills/dark-factory-import
```

Then, from **your project's repo** (not this one), start Session 0:

```bash
cd /path/to/your-project
claude
# then say: import the dark factory from /path/to/dark-factory
```

## What happens on your first import

Session 0 follows `INSTALL.md`'s phases, and it starts by trying to refuse
you. That is by design.

1. **Prerequisites & refusals.** You need a PRD with non-goals (no PRD → no
   out-of-scope list → triage can't reject → scope rot with nobody watching),
   observable software, a real test command that fails when the product is
   broken, a human owner, `gh` auth, and a machine that stays on. Missing any
   one, the skill stops.
2. **Engine copy.** `factory/` + `harness/` land in your repo byte-identical
   to this one — verified with `diff -r`, versioned by `ENGINE_PIN`.
3. **Governance fill-in.** You fill `templates/` into your own `MISSION.md`,
   `FACTORY_RULES.md`, `FACTORY.md`, and `CLAUDE.md` block. Every filled file
   is a human commit and goes straight onto the protected list.
4. **Binding.** `factory/config.sh` is authored fresh for your project;
   `guard.py`'s protected list is rewritten; the validation families, E2E
   journeys, holdout scenarios, floor counts, and mutation defects become
   yours (the shipped ones are worked examples from the source product —
   proving the gate against someone else's bugs proves nothing).
5. **Prove it can fail.** Labels, machinery self-checks, `harness/ci.py
   --prove`, the notify channel, and the stop button — each tested on
   purpose before anything is armed.
6. **Dial up slowly.** The factory starts at **dial 0**: it builds, a human
   signs `factory:accepted`, a human merges. One notch per watched cycle,
   each notch an explicit human go. The scheduled trigger is installed last.

The conservative defaults are the point: dial 0, human signature required,
no production-DB road, evolution auto-apply OFF, no artifact-build road. Each
is enabled later by its own human commit, one at a time — or never.

## How work gets in

The factory eats GitHub issues, and the judge reads ONLY the issue as filed —
so how issues get written matters as much as how they get processed. Two paths:

1. **File one by hand.** Plain words are fine, but it must describe something
   observable: a bug with reproduction or error output, a feature inside
   MISSION's scope, performance work with a measurable claim, docs, or tests
   for uncovered behavior (`FACTORY_RULES` §1 is the triage contract). Each
   issue is self-contained: its own context, acceptance criteria, and fences.
   Underspecified-but-workable issues don't bounce — the factory records its
   assumptions and an independent judge rules on them, holding the merge if a
   recorded assumption was a real decision.
2. **Use the intake skill for anything bigger than one lap.**
   `skills/factory-intake/` is the front door: it detects whether the work fits
   the factory's territory, sizes the planning depth (PRD → architecture →
   slice, skipping what the size doesn't warrant), files self-contained issues
   in dependency order, and hands back the one human act — the list to label.

```bash
ln -s "$(pwd)/dark-factory/skills/factory-intake" ~/.claude/skills/factory-intake
```

Either way, nothing runs until a human puts `factory:accepted` on the issue.
Filing is anyone's job; signing is yours.

## Layout

| Path | What it is |
|---|---|
| `factory/` | The engine: orchestrator, tick, runner, gate, merge, deploy, db-apply, evolution loop, state machine, guard, prompts. Extracted byte-identical from a pinned commit of the source repo (modulo the identifier scrub — see `ENGINE_PIN` and `scripts/sync-from-source.sh`). |
| `harness/` | The source project's validation gate (`ci.py` ladder + families). The ladder mechanics are the spec; the families are worked examples you replace. |
| `templates/` | Governance templates: `MISSION.template.md`, `FACTORY_RULES.template.md`, `FACTORY.template.md`, `CLAUDE.template.md`, plus `gitignore.snippet`. Filled per project, by a human, as human commits. |
| `.factory/` | Runtime-state scaffolding, shipped empty on purpose. |
| `docs/factory/` | Template stubs for the operationally load-bearing docs. |
| `INSTALL.md` | The binding procedure — every fact the import skill enforces. |
| `ADAPTERS.md` | The honest map: what's generic, what's config, what's shaped around the source stack (Supabase/Expo), what swapping it takes, and every known dangling reference. |
| `skills/dark-factory-import/` | The Session-0 import skill (interactive, refusal-gated). |
| `scripts/sync-from-source.sh` | Re-extracts the engine from a new pinned commit of the source repo in one command. |
| `ENGINE_PIN` | The commit this engine was extracted from, plus hashes of the governance files the templates were derived from. |
| `NOTES.md` | Working lessons from the export itself. |

## Reading order

`INSTALL.md` for the binding facts. `ADAPTERS.md` before you touch anything —
it is the honesty map of what is generic and what is shaped like the source
project. `templates/` to see what you'll be asked to write. The engine's own
comments carry the design history: most non-obvious lines say which real
failure taught them.

## What this repo is not

- Not a framework. It's a working machine, extracted honestly — some parts
  are shaped like the project it came from (`ADAPTERS.md` names every one).
- Not self-governing. The governance files are filled and committed by
  humans, and no agent may edit the rules it is judged by.
- Not runnable here. Nothing in this repo should ever tick; there is no
  bound project, no config values, no trigger.
