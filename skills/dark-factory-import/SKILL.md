---
name: dark-factory-import
description: Bind the standalone dark-factory engine into a project repo (Session 0). Use when the user says "import the dark factory", "bind the factory to this repo", "new project factory setup", or "session 0 for the factory". Copies the engine byte-identical from the dark-factory repo, walks the governance fill-in and binding with its refusal gates, verifies the gate can fail, and ends in one clean commit with a closeout report. Same engine, different ignition key.
---

# Dark-Factory Import (Session 0)

You are binding a proven engine to a new project. The engine files never
change; only the binding does: governance content, `config.sh`, `guard.py`'s
protected list, the validation-harness families, prompts, holdout, floor,
defects. `INSTALL.md` in the dark-factory repo is the reference for every
fact; this skill is the procedure and its gates. Do not reorder phases.

## Inputs — refuse to start without all five

1. Path to the dark-factory repo (engine source; read-only for this session).
2. Path to the target project repo.
3. The project's PRD **with non-goals**. No PRD → refuse: "The factory
   cannot reject scope it was never given. Write the PRD first."
4. A test command that fails when the product is broken (or a
   walking-skeleton plan that produces one before the first lap).
5. The human owner, present — they will approve the protected list and the
   governance files, and they hold the dial.

Record the dark-factory repo's `ENGINE_PIN` contents in your session notes;
that is the engine version being imported.

## Hard rules

- The dark-factory repo is read-only. If an engine change seems needed, stop
  and raise it — that is an upstream decision, not an import decision.
- Never copy state: no runs, ledgers, evolution history, cost logs, floor
  values, holdout scenarios, or defects from any other project. The new
  factory's history starts empty.
- Every governance file is a human-approved commit. Never invent, soften, or
  upgrade a policy the human did not state.
- Nothing autonomous in this session: dial stays 0, no trigger install, no
  labels-driven dispatch. Session 0 ends with a factory that has never ticked.
- Write in US register: say "coworker", "teammate", or "company member" —
  British-slang address terms are banned in anything you write.

## Phases

**0 — Environment audit.** Run the Phase-0 machine audit from INSTALL.md
(`gh auth status`, python ≥ 3.10, stable node path, agent CLI, cloud-sync
shield decision). Record findings. A failed item is a listed prerequisite in
the closeout, not a silent skip.

**1 — Engine copy.** Copy `factory/` and `harness/` from the dark-factory
repo into the target, then verify byte-identity with `diff -r` (zero
differences). Copy the `.factory/` scaffolding. Append
`templates/gitignore.snippet` to the target's `.gitignore`, then run
`git check-ignore -v` over every secret-bearing file — empty output for any
of them halts the import.

**2 — Governance fill-in.** Walk the human through each template
(`MISSION`, `FACTORY_RULES`, `FACTORY`, `CLAUDE` block). You may draft from
the PRD; the human approves every section. §-numbers and headings are
load-bearing — never renumber. Then the **readback gate**: read the
protected-files list, the out-of-scope list, and the permanently-human list
back to the human and get explicit approval before any of it is committed.
Verify no `{{` survives in any filled governance file.

**3 — Config + guard binding.** Author `factory/config.sh` fresh (never
copy-edit another project's). Values you cannot know yet are `TBD-<phase>`,
never guessed. Rewrite `guard.py`'s PROTECTED list per the approved readback.
Dial is 0. Deploy/db/TF/brain knobs stay unset/off unless the human
explicitly enables that road.

**4 — Gate binding.** Per INSTALL.md Phase 4: families in
`harness.config.json`, `appproc.py` stack layer, `e2e.py` journeys, holdout
scenarios, floor seeding, defects re-seed, prompt rewrites (preserving the
machinery contracts ADAPTERS.md lists). Where the project's scaffold does
not exist yet, mark the family `TBD-<slice>` and leave its conditional
marker honest — an unchecked surface must never read as a pass.

**5 — Verification gauntlet.** In order: (a) run the gate; every family
passes or prints its legal skip reason — a silent skip is a failure;
(b) prove the gate can fail — break a marker on purpose, watch non-zero,
revert, re-verify clean tree; (c) `init-labels.sh` if the repo backend is
GitHub; (d) test notify and both stop-button halves on purpose, record the
date; (e) final `diff -r` of the engine against the dark-factory repo —
still byte-identical.

**6 — One clean commit + closeout.** A single commit containing the engine,
scaffolding, filled governance, and binding — pushed only with the human
present. Then write the closeout report: engine pin imported, every
`TBD-*`, every failed/waived Phase-0 item, the unarmed trigger, dial 0, and
the exact next human actions (first hand-driven lap, then one notch per
watched cycle). The importing project has not earned a tick yet; say so
plainly.
