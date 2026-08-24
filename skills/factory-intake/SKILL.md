---
name: factory-intake
description: "The front door for feeding a dark factory — takes a raw idea, an existing roadmap item, or 'what should the factory do next', detects which lane applies (factory-ready work, in-repo but out-of-territory work, or greenfield with no factory yet), routes it through the right planning depth (PRD → architecture → slice, skipping what the size doesn't warrant), and ends with filed GitHub issues plus a label-these-first list — or an honest handoff when the factory can't take it. Use when the user says 'factory intake', 'feed the factory', 'what should the factory do next', 'I want to build/add [feature]', 'kick off [feature] in the factory', 'queue this up for the factory', or invokes /factory-intake. Never labels issues factory:accepted — the label is the human's signature."
argument-hint: "[idea, feature, roadmap item, or blank to scan the backlog]"
---

# Factory Intake — from idea to fueled factory

Take whatever the user brings — a raw idea, a named roadmap item, or nothing — and get
it to the point where the dark factory can pick it up: issues filed, dependency order
known, and the one human act (labeling) handed back clearly. The skill decides the
lane and the planning depth; the user decides the work and signs it.

Like the rest of this export, parts of this skill are shaped by the project it came
from; those spots are marked "in the source project" and are worked examples, not
requirements.

## Step 0 — Detect the lane (never ask what can be checked)

Check the target repo (cwd, or the repo the user names):

- **Factory present?** `factory/` dir + `FACTORY_RULES.md` at root + the
  `factory:accepted` label existing on the GitHub repo (`gh label list`).
- **Territory?** Read MISSION.md / FACTORY_RULES.md for the factory's declared
  territory (in the source project: server-side only — edge functions, migrations,
  services; client work was outside it until a deliberate expansion).

Three lanes:

1. **Factory-ready** — factory present AND the work fits its territory → full
   pipeline below, ending in filed issues.
2. **Out-of-territory** — factory present, work outside its territory → run the same
   planning, but END by saying so plainly: the output lands as interactive-session
   work, OR the user makes the territory-expansion decision (a governance change,
   theirs, never this skill's). Do not file factory issues that will only ever hold.
3. **Greenfield / no factory** — no factory in the repo (or no repo yet) → PRD-first
   planning, then a clean handoff: "this needs a factory built first — that is the
   binding procedure in this repo's INSTALL.md, a human-present Session 0, not
   something to attempt from inside an intake pass." Never silently attempt factory
   construction from here.

State the detected lane in one sentence before proceeding, so a wrong detection gets
corrected in five seconds, not after an hour of planning.

## Step 1 — Resolve the intent

- **The user brought an idea or named item** → restate it in one sentence, confirm.
- **Blank, or "what's next?"** → scan the repo's backlog sources and present the top
  3–5 candidates with a one-line why-now each (ready dependencies, user impact,
  factory-eligibility). Look for, roughly in this order: a launch punch list or
  status doc; the roadmap doc MISSION.md names as the standing work source;
  `.factory/followups/*.md` (sub-issues the factory itself proposed);
  `.factory/evolution/RECOMMENDATIONS.md` open blocks; formal sprint/epic state if
  the repo keeps one; and parked specs not yet built. Say what was found and where —
  and say plainly when a source doesn't exist in this repo.

## Step 2 — Size the planning depth

| Size | Signs | Route |
|---|---|---|
| **Single-lap** | one concern, roughly ≤1,500 lines including tests, no architecture fork | Skip planning — write the issue directly (Step 4) |
| **Feature / epic** | several concerns, real design forks, touches more than one area | architecture pass → slice into laps |
| **Product / greenfield** | new product surface, no existing thesis | PRD → architecture → slice |

State the chosen size + route in one line; let the user override before running.

## Step 3 — Run the planning

If you have planning skills installed for PRD, architecture, and epic-slicing (the
source project uses Cole Medin's `plan-create-prd`, `plan-architecture`, and
`piv-slice-epic`), invoke them and ground the architecture pass in the repo's real
context (ADRs, locked defaults, the memory/brain repo if one exists). If they're not
installed, say so and do the equivalent planning by hand — deliberately, not as an
improvised shortcut. Save outputs under `docs/specs/`.

## Step 4 — File the issues (lane 1 only)

- One GitHub issue per ticket, **self-contained** — the factory's judge reads ONLY
  the issue as filed, so each carries its own context, acceptance criteria, and
  fences (what it must NOT touch). Single-lap work gets the same shape by hand.
- What triage accepts (see FACTORY_RULES §1 as bound in the target repo): something
  observable — a bug with reproduction or error output, a feature matching MISSION's
  scope, performance work with a measurable claim, docs, tests for uncovered existing
  behavior. Vague wishes get rejected by the machine you're feeding.
- If GitHub's GraphQL API flakes (503s happen), file via REST:
  `gh api repos/<owner>/<repo>/issues -f title=... -f body=...`.
- **NEVER add `factory:accepted` or a priority label.** The label is the human's
  signature — filing is this skill's job, accepting is theirs.
- If a slice needs a schema change, bundle the migration WITH its consumers in one
  ticket where reasonable — in a repo with a human prod-apply floor, each
  migration-carrying lap costs one human step, so fewer carriers = fewer
  interruptions. (Check FACTORY_RULES/MISSION for the current prod-apply rule rather
  than assuming; governance is the authority, never this skill.)

## Step 5 — Hand back the one human act

End with exactly this, filled in:

```
Filed: #N <title> · #M <title> ...
Label these now (factory:accepted + a priority): #N, #P   ← wave 1, independent
Hold these until their dependency merges: #M (after #N) ...
The next tick takes it from there. You'll get LAP DONE per finished lap,
or a needs-human message with the flagged assumptions when something needs you.
```

For lanes 2–3, replace the label block with the honest ending from Step 0.

## Step 6 — Stage the shepherd session (optional but recommended)

Filed work usually wants a watch session — an interactive agent session named for the
task, watching the lap land. The operator's half: open a terminal, run the agent, name
the session. Your half, in order — the ORDER is the whole protocol:

1. **Name the session for the task — one or two words, max.** Task-aligned, not
   process-aligned: "issue 25", "Portal Intake" — never "Factory Session 3". State
   the exact name in your close-out so the operator can create it verbatim.
2. **Write the kickoff doc BEFORE the session exists** —
   `.agents/handoff/KICKOFF-<slug>.md`, committed: a verified state block (shas,
   labels, what's in flight — checked, not remembered), what a good outcome looks
   like, precedents and limits, and the standing constraints. The session reads the
   doc; the message just points at it.
3. **Check the session roster FIRST — before arming any watcher.** Operators often
   create the session ahead of you. If a session with the target name already
   exists, send it the kickoff immediately and you are done.
4. **Only if it does not exist yet:** tell the operator the exact name, then arm a
   background watcher for NEW arrivals and re-check the roster by name on each wake.
   A watcher's baseline is taken at arm time — a session created BEFORE the baseline
   never trips it, which is exactly why step 3 precedes step 4. (Learned live in the
   source project: a pre-existing session sat undetected behind a new-arrivals
   watcher.)
5. The kickoff message ends with who shepherds what — one session per lap or step,
   and never re-assign a lap another session already owns.

## Gotchas

- The factory runs ONE lap at a time; the dependency waves are the feeding schedule —
  accepting a dependent ticket early just makes it hold.
- A dependent ticket is planned when its dependency is IMPLEMENTED, not when it's
  sliced — in factory terms, when its lap has merged. Don't over-specify wave-2
  issues against a guess.
- Territory and label decisions are always the human's; this skill detects and
  recommends, never decides either.

## Resources (read at need, never copied)

- Issue-writing rules: the bound repo's `FACTORY_RULES.md` §1 (what triage accepts)
  and `MISSION.md` (scope + non-goals — triage rejects against these).
- This repo's `INSTALL.md` for the lane-3 handoff (building a factory is Session 0,
  human-present).
