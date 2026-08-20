# harness/ — the VOX validation harness (dark factory, component 5)

One command decides whether the software works:

```bash
python3 harness/ci.py            # the whole gate
python3 harness/ci.py --quick    # strict subset an implementing agent may self-run
python3 harness/ci.py --prove    # whole gate + the mutation proof (breaks VOX on
                                 # purpose and requires the gate to notice)
```

The full map — ladder, markers, the two E2E journeys, holdout, mutations, floor,
every deliberate departure from the build-dark-factory template, and the proof
transcript — lives in **`docs/factory/phase-b-validation-harness.md`**. The gate's
canonical wording is `MISSION.md` § Definition of done; operating rules are
`FACTORY_RULES.md` (§3 gates, §5 protected files, §9 the holdout).

Layout:

```
harness/
  ci.py                 the entrypoint — future FACTORY_VALIDATE_CMD
  harness.config.json   every command the ladder runs, plus app/env wiring
  appproc.py            the driver: local Supabase stack + functions serve,
                        vault seeding, serve-env assembly, http helpers
  e2e.py                MISSION Gate 3: pipeline primary + query secondary
  fixtures/             the committed audio the pipeline E2E uploads
  mutations/            run.py + defects.json — the proof the gate can fail
.factory/
  holdout/run.py        assertions the builder may NEVER read (see .factory/README.md)
  locks/floor.json      the ratchet — human commits only
  runs/                 per-run artifacts, gitignored
  STOP                  create this file to stop the line (checked before any rung)
```

This directory is **protected** (`FACTORY_RULES.md` §5): the builder may read and
run it, never edit it. Legitimate coverage growth goes in the normal test
directories; a builder that can edit its own judge can make any claim true.
