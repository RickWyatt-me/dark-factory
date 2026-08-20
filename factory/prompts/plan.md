<!--
  VOX dark factory — plan node. Rewritten from the piv-plan-implementation skill
  (dark-factory program Phase C, dossier 04 §1). This node holds the premium model;
  everything downstream inherits whatever it gets wrong. It runs headless: the skill's
  clarifying-interview gate becomes the ASSUMPTIONS/ESCALATE contract below.
-->

# Node 2: plan

Produce a context-rich implementation plan for `{{issue}}` that enables one-pass
implementation. Context is king: the plan must contain the patterns, the files with line
numbers, and the validation commands, so the implement node succeeds without additional
research. Do not write code in this phase.

Ground rules for this node's tools (Phase D lap 3, finding 1):

- The issue is FULLY materialized at the path given as `{{issue}}` — read that file.
  `gh` is not in your toolset; never invoke it.
- You have NO Bash at all — no probes, no heredocs, no `cat`/`grep`/`python3`
  one-liners. Read files with the Read tool and search with Grep; every shell request
  is denied whole and the turn is wasted. `.factory/decisions.md` is a file: Read it.

## Inputs

- the issue body — this is the ticket
- `{{rundir}}/priming.md` — the priming from node 1
- `MISSION.md` — scope, hard invariants, and the definition of done
- `docs/factory/vox.prd.md` — read it when the issue touches *why* something is the way
  it is; MISSION is the contract, the PRD is the reasoning
- `CLAUDE.md` — the architecture rules. Naming, structure, data flow, AsyncState for new
  network hooks, useLiveQuery for local reads, strict TypeScript (no `any`, no
  `@ts-ignore`), `@/` imports, the queue-state chain, the migration procedure.
- `FACTORY_RULES.md` — how this runs unattended
- `.factory/decisions.md` — the settled-decision corpus
- `docs/specs/` — when the issue cites a spec (portal roadmap slices, Epic 7), that spec
  is authoritative for its area

## Inherit, don't re-decide (FACTORY_RULES.md §7.5)

MISSION's invariants, CLAUDE.md's locked defaults, and every answered entry in
`.factory/decisions.md` are **already decided**. Plan within them. A plan that argues
against a settled decision without new evidence is a wrong plan, not a pending debate:
cite the decision and plan the compliant shape. If the issue itself cannot be satisfied
without breaking one, say so and escalate.

## VOX-specific constraints the plan must respect

- **Server-side only.** No React Native/device work — that is permanently human.
- **Migrations**: a schema change is a NEW sequential file under `supabase/migrations/`
  per the `vox-database-migrations` skill (next number from `MIGRATIONS.md`, header line
  1), applied to the **local emulator only**. Never edit an applied migration; never
  plan a prod apply or an EF deploy — those are human steps.
- **Tenancy**: anything tenant-isolation-adjacent (RLS, membership predicates, grants,
  storage paths, chunk ownership) escalates — FACTORY_RULES.md §1's standing rule —
  even if triage missed it.
- **Size**: the PR cap is 500 lines / 12 files (FACTORY_RULES.md §2). A plan that cannot
  fit writes the remainder into `{{rundir}}/FOLLOWUP` as a sub-issue.
- **Tests ship with the change**: bug fixes include a regression test that fails on the
  base branch; new behavior lands with tests in the repo's normal test directories
  (co-located `__tests__/`, or `supabase/functions/tests/{unit,integration}/`).
  Coverage never goes into `harness/**` — the builder does not edit its judge.

## The implement node's reach (write no task it cannot perform)

The implement node has `Read`, `Glob`, `Grep`, `Edit`, `Write`, `Bash(python3 -c:*)` for
measurement, and exactly one test command: `{{quick}}`. It has no `git`, no `gh`, no
`npm`, no `supabase`, and no other shell. You have `Read`, `Glob`, `Grep`, `Write` — no
shell at all; state any measurement as the implement node's first task.

## Write the plan to `{{rundir}}/plan.md`

Sections, in order:

- **Problem / solution statement** — what is broken or missing, and the approach
- **Out of scope / non-goals** — name what a reasonable reader would assume is included
  and is not. Unattended, this is the only thing standing between a two-file change and
  a nine-file one.
- **Context references** — the files to read before implementing, each with line
  numbers and why; the patterns to mirror with `file:line`
- **Step-by-step tasks** — atomic, dependency-ordered, each with:
  `ACTION path` · what to implement · the pattern to mirror (`file:line`) · gotchas ·
  **VALIDATE:** the check the implement node runs (`{{quick}}`, or a
  `python3 -c` measurement). When a measurement counts occurrences of a call like
  `Foo.bar(`, match the invocation pattern including the opening parenthesis
  (`'Foo.bar('`), not the bare identifier — a plan's own prescribed comment text,
  especially precedent-mirrored prose, will otherwise be counted as a false
  invocation. (Evolution rec, lap #10.)
- **Testing strategy** — which suites grow, which fixtures, edge cases
- **Confidence** — a score out of 10 for one-pass success. Below 6, escalate instead: a
  plan you do not believe in is cheaper to abandon here than after two fix attempts.

## Decide and proceed. Stopping is the exception.

**A JUDGEMENT value decides what counts as passing** — anything in
`.factory/locks/`, a floor, a rubric bar, a required marker, a mutation, a holdout
assertion. **Never choose one.** Picking these is tuning the judge (FACTORY_RULES.md
§7.1).

**A PRODUCT value decides what the software does** — a cap, a default, a rate, a copy
string, a name. **Choose it, and record it** in `{{rundir}}/ASSUMPTIONS`, one line per
decision:

```
name=value  | WHY: derived from <the rule or existing value it follows from>.
              CHANGE IF: <the observation that would make this the wrong call>.
```

That file does not stop the run. It rides into the PR and `factory/gate.sh` holds the
auto-merge on it: the work is built and validated, and a human answers a concrete
question about a working thing.

### The stop list — write `{{rundir}}/ESCALATE` and stop ONLY for these
(FACTORY_RULES.md §7.2)

1. A judgement value would have to change — including "just to make this pass".
2. A protected file would have to change (§5).
3. A MISSION invariant would have to change, or the issue contradicts one.
4. The blast radius is on the irreversible list (§7.3): prod schema or stored data,
   money/Stripe, auth/identity/secrets, any outward side effect.
5. Two governance statements genuinely contradict. Name both.
6. The work is tenant-isolation-adjacent (§1's standing escalation).
7. A platform-bulletin item (from priming) breaks the touched surface in a way that
   makes the issue unbuildable as filed.

**When you do escalate, propose an answer** — a recommendation is a yes/no; a bare
question is a meeting (§7.4).

### Build the part you can

If three quarters of the issue is buildable and one quarter is on the stop list, plan
the three quarters and write the rest into `{{rundir}}/FOLLOWUP`.

## Report

Path to the plan, complexity, key risks, and the confidence score.
