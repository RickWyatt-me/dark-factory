# dark-factory

A standalone export of a working **dark factory**: an unsupervised build loop
where work enters as GitHub issues and validated code merges and deploys with
nobody at the keyboard — gated by a marker-verified validation ladder, a
protected-files guard, independent judge agents, a graduated autonomy dial,
and a stop button that fails closed.

This repo is the **engine + templates + binding procedure**. It builds
nothing by itself: a factory only exists once this engine is bound to a
project — its own MISSION, its own gates, its own protected list, its own
human.

## Layout

| Path | What it is |
|---|---|
| `factory/` | The engine: orchestrator, tick, runner, gate, merge, deploy, db-apply, evolution loop, state machine, guard, prompts. Extracted byte-identical from a pinned commit of the source repo (modulo the identifier scrub — see `ENGINE_PIN` and `scripts/sync-from-source.sh`). |
| `harness/` | The source project's validation gate (`ci.py` ladder + families). The ladder mechanics are the spec; the families are worked examples you replace. |
| `templates/` | Governance templates: `MISSION.template.md`, `FACTORY_RULES.template.md`, `FACTORY.template.md`, `CLAUDE.template.md`, plus `gitignore.snippet`. Filled per project, by a human, as human commits. |
| `.factory/` | Runtime-state scaffolding, shipped empty on purpose. |
| `docs/factory/` | Template stubs for the operationally load-bearing docs. |
| `INSTALL.md` | The binding procedure — how a project imports and arms this. |
| `ADAPTERS.md` | The honest map: what's generic, what's config, what's shaped around the source stack (Supabase/Expo) and what swapping it takes. |
| `skills/dark-factory-import/` | The import skill (interactive, refusal-gated) — the procedure INSTALL.md documents, enforced. |
| `scripts/sync-from-source.sh` | Re-extracts the engine from a new pinned commit of the source repo in one command. |
| `ENGINE_PIN` | The commit this engine was extracted from, plus hashes of the governance files the templates were derived from. |
| `NOTES.md` | Working lessons from the export itself. |

## The short version of importing

Read `INSTALL.md` (or run the `dark-factory-import` skill). The shape:

1. **Prerequisites & refusals** — PRD, observable software, a test command,
   a human owner, `gh` auth, a machine that stays on. No PRD → no factory.
2. **Copy the engine** — `factory/` + `harness/` plumbing, byte-identical.
3. **Fill the governance templates** — human commits; the filled files go
   straight onto the protected list.
4. **Bind** — author `factory/config.sh` fresh; rewrite `guard.py`'s
   protected list; supply your own gates, E2E, holdout, floor, defects.
5. **Prove** — labels, machinery self-checks, `harness/ci.py --prove`,
   notify + stop button tested on purpose.
6. **Dial up slowly** — dial 0, one lap by hand; one notch per watched
   cycle, each notch an explicit human go. Trigger install comes last.

Conservative defaults everywhere: dial 0, a human signs `factory:accepted`,
no prod-DB road, evolution auto-apply OFF, no artifact-build road.

## What this repo is not

- Not a framework. It's a working machine, extracted honestly — some parts
  are shaped like the project it came from (`ADAPTERS.md` names every one).
- Not self-governing. The governance files are filled and committed by
  humans, and no agent may edit the rules it is judged by.
- Not runnable here. Nothing in this repo should ever tick; there is no
  bound project, no config values, no trigger.
