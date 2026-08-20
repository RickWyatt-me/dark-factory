<!-- TEMPLATE — MISSION.template.md
     Copy to your repo root as MISSION.md and fill every {{SLOT}} / FILL block.
     The section headings and the mechanics sentences are load-bearing: the
     factory's rules and judge prompts cite MISSION sections by name. Fill
     content; never rename, reorder, or delete a section. Delete each
     FILL comment when its slot is filled. -->

# Mission

<!-- Owner: humans only. Protected — the factory cannot edit this file.
     When the product changes, this file changes in the same human commit. -->

**Derived from:** `{{PRD_PATH}}`
**Last reconciled with that PRD:** {{RECONCILED_DATE}}

## What {{PROJECT_NAME}} is

<!-- FILL: One paragraph — what the product does, for whom, and what the output
     is. Keep it under 10 lines; every judge reads this at reject time. -->

{{PRODUCT_DESCRIPTION}}

<!-- FILL: One short paragraph naming the 2–3 baked-in assumptions that harden
     into the Hard invariants below (e.g. an isolation boundary, an availability
     constraint, a north-star KPI). -->

Baked-in assumptions that become invariants below: {{BAKED_IN_ASSUMPTIONS}}

## Who it is for

<!-- FILL: The personas, one bullet each, plus one "we are not X" line naming
     the adjacent product category this is NOT trying to be. -->

- {{PRIMARY_PERSONA}}
- {{SECONDARY_PERSONA}}

{{PROJECT_NAME}} is not {{WHAT_IT_IS_NOT}}.

## Core capabilities (in scope)

The factory may accept issues in these areas, each verified by its own gate rung;
whatever no check can see is judged by a human, never by a gate:

<!-- FILL: One bold-titled paragraph per capability area the factory owns. Be
     concrete — these lines are the territory declaration triage rules against.
     If part of the surface merges gate-green but still needs a human look
     (visual work, device feel), say here which label flags it and who judges. -->

**{{CAPABILITY_1}}** — {{CAPABILITY_1_DETAIL}}

**{{CAPABILITY_2}}** — {{CAPABILITY_2_DETAIL}}

## Out of scope (the factory must never build this)

Issues asking for any of these are rejected at triage, even when well argued and easy to
build. Deferred work lives in the backlog and is deliberately NOT on this list.

<!-- FILL: Grouped bullets of the things this product will never build. Derive
     from the PRD's non-goals. Anything money-moving or record-authority-shaped
     belongs here explicitly. -->

**{{OUT_OF_SCOPE_GROUP_1}}**
- {{OUT_OF_SCOPE_ITEM}}

## Hard invariants (not tunable by any issue)

1. **The factory cannot modify governance files.** `MISSION.md`, `FACTORY_RULES.md`, and
   `CLAUDE.md` are the constitution. A PR touching any of them is an automatic reject.

<!-- FILL: Append the product's own invariants as 2, 3, … — properties no issue
     may relax, stated absolutely. Worked patterns from the source project,
     offered as examples, not defaults: an isolation wall between tenants; "no
     destruction of data without positive provenance that the destroyer owns
     it"; "composed numbers come from rows, never prose" (aggregates derive from
     structured data, a model never invents a figure). -->

2. **{{INVARIANT_2}}.** {{INVARIANT_2_DETAIL}}

## Allowed evolutions

Explicitly in scope, so the factory does not reject them as drift:

- Test-coverage growth (in the normal test directories, never in the validation harness).
<!-- FILL: Add the improvement classes that are always welcome — e.g. latency/
     cost/reliability inside existing stages; refactors that preserve the
     repo's canonical data flow (name it). -->
- {{ALLOWED_EVOLUTION_2}}

## Definition of done

Every change the factory ships clears all three gates. Exact commands and markers are the
validation harness's contract (`FACTORY_RULES.md` §3 tracks status).

**Gate 1 — static checks and tests pass.** <!-- FILL: name the repo's suites -->
{{GATE_1_FAMILIES}} — the repo's existing suites, green.

**Gate 2 — fidelity holds.** <!-- FILL: the quality/fidelity checks with a fixed
     bar, if any; if none yet, state what will fill this gate and when -->
{{GATE_2_FAMILIES}}

**Gate 3 — the end-to-end paths pass as a real user:**

<!-- FILL: The 1–2 journeys a real user takes, as numbered paths with observable
     stages, driven against the local stack. These are the paths §4 makes
     mandatory on every PR touching runnable code. -->

1. *{{E2E_PATH_1_NAME}} (primary):* {{E2E_PATH_1_STAGES}}
2. *{{E2E_PATH_2_NAME}} (secondary):* {{E2E_PATH_2_STAGES}}

## Non-goals

{{PROJECT_NAME}} is explicitly not trying to be: {{NON_GOALS_LIST}}. When in doubt, the
answer is "that is out of scope."

## Open questions — decisions nobody has made yet

These are undecided, not forbidden. **The factory may propose an answer**, build against it,
record the assumption, and the merge is held for a human (`FACTORY_RULES.md` §7). Answered
entries move to `.factory/decisions.md` and stop being asked.

<!-- FILL: The genuinely open product decisions, one Q-numbered bullet each.
     Keep this list current — a stale open question invites re-litigation. -->

- **Q1** {{OPEN_QUESTION_1}}

**Except these, which do stop the factory** — they are on the irreversible list
(`FACTORY_RULES.md` §7.3):

- Anything changing identity, auth, or who may act as whom.
- Anything migrating or deleting stored production data.

## What the factory does NOT own — permanently human

<!-- FILL: Each bullet below is a generic boundary — replace the slot text with
     your project's concrete version, or delete a bullet only if it truly does
     not apply (money and destruction never stop applying). -->

- **Whatever no check can see.** {{HUMAN_JUDGED_SURFACE}} — no gate will ever see it;
  a person judges it.
- **Destroying stored data, and the money/identity schemas.** {{HUMAN_FLOOR_DETAIL}}
- **Promotion to the known-good branch and every external release.**
  {{INTEGRATION_BRANCH}} → {{RELEASE_BRANCH}} and anything reaching a user who is not the
  owner stays human.
- **Adjacent repos outside this territory.** {{ADJACENT_REPOS}}

The factory owns {{FACTORY_TERRITORY_SUMMARY}} — where most of the actual risk lives.
A green gate means that layer is intact, never that the product is good.
