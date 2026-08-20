# Holdout scenarios — the assertions the builder never reads

Write `run.py` here **before the first factory-built feature**. Compose every scenario
from bugs that actually escaped your visible checks — the point is judging outcomes the
builder-side gate cannot anticipate. The builder-side gate may know THAT this file runs;
it must never know WHAT it asserts.

The four rules (repeat the long form in each scenario file):

1. **Written before the work.** A scenario written after seeing the implementation is
   a description of the implementation.
2. **Duplicate, do not import** builder-side helpers. The one carve-out is process/env
   management (starting the stack is not an assertion). Every request helper and every
   assertion is DUPLICATED so no builder-side refactor can re-couple the judge to code
   the builder edits.
3. **Compose.** Each scenario is several features used together, the way real failures
   present — feature isolation is the dominant real failure, not cheating.
4. **Inputs that appear nowhere else in the repo.**

Contract: `run.py` emits `HOLDOUT_PASSED scenarios=N assertions=M` on success; any
failure exits non-zero. Seed `locks/floor.json`'s `holdout_scenarios` /
`holdout_assertions` counts from your first honest green run, by human commit.
