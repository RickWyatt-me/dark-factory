#!/usr/bin/env python3
"""The gate's entrypoint. FACTORY_VALIDATE_CMD points here.

    python3 harness/ci.py             the whole gate
    python3 harness/ci.py --quick     the cheap strict subset (static + jest unit)
    python3 harness/ci.py --prove     the whole gate PLUS the mutation proof
    python3 harness/ci.py --families unit,e2e
                                      a named subset — the mutation runner's tool.
                                      Never prints GATE_OK; a partial run can fail
                                      the gate but can never pass it.

THE CONTRACT (references/validation-harness.md, kept exactly):
  1. A POSITIVE marker for every family that RAN, with a COUNT.
  2. Exit NON-ZERO when the software is broken.
  3. Print to STDOUT; the runner appends this to guard.py's output in one gate.log.
  4. --quick is a STRICT subset — never a check the full run lacks.

THE VOX LADDER (families, cheap first — see harness.config.json for the commands):
  static       eslint + tsc                                       STATIC_OK
  unit         jest                                               UNIT_PASSED
  ef_unit      deno EF unit + source-scan invariants              EF_UNIT_PASSED
  fidelity     kv-fidelity (deterministic magnitude guard)        FIDELITY_OK
  integration  jest integration against the local stack           INTEGRATION_PASSED
  e2e          MISSION Gate 3: pipeline primary + query secondary APP_STARTED,
               over http, real mode                               E2E_PIPELINE_PASSED,
                                                                  E2E_QUERY_PASSED
  holdout      .factory/holdout/run.py — above the line           HOLDOUT_PASSED
  compile_eval lockstep drift guard + writing-quality judge       COMPILE_EVAL_PASSED
  (floor)      the ratchet — observed vs .factory/locks/floor.json FLOOR_OK

MUTATIONS run under --prove (or standalone: python3 harness/mutations/run.py), not on
every lap: each defect re-runs gate families against the live stack, which is minutes
and real API spend per defect. A per-lap gate that nobody can afford to run stops
being run — the honest trade is a separate standing proof obligation, surfaced every
lap as MUTATIONS_DEFERRED so a lap log never implies the proof happened here.

THE STOP BUTTON IS CHECKED FIRST. If .factory/STOP exists this prints
FACTORY_STOPPED and exits non-zero before any rung runs (STOP_FILE mechanism —
see .factory/README.md).
"""
from __future__ import annotations

import copy
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
STOP_FILE = ROOT / ".factory" / "STOP"
FLOOR_FILE = ROOT / ".factory" / "locks" / "floor.json"
HOLDOUT = ROOT / ".factory" / "holdout" / "run.py"

CONFIG = json.loads((HERE / "harness.config.json").read_text(encoding="utf-8"))

QUICK = "--quick" in sys.argv
PROVE = "--prove" in sys.argv
FAMILIES: list[str] | None = None
if "--families" in sys.argv:
    FAMILIES = sys.argv[sys.argv.index("--families") + 1].split(",")

COUNTS: dict[str, int] = {}


def resolve(argv: list[str]) -> list[str]:
    """Resolve argv[0] through PATH so config commands stay what you would type."""
    if not argv:
        return argv
    head = argv[0].strip("\"'")
    return [shutil.which(head) or head, *argv[1:]]


def run(cmd: str, timeout: int = 600, extra_env: dict[str, str] | None = None
        ) -> tuple[int, str]:
    """One command. A timeout is a FAILURE, not a skip."""
    argv = resolve(shlex.split(cmd))
    env = dict(os.environ, **(extra_env or {}))
    try:
        p = subprocess.run(argv, cwd=ROOT, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout,
                           env=env)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, f"TIMEOUT after {timeout}s"
    except OSError as e:
        return 127, f"could not run {argv[0] if argv else cmd!r}: {e}"


def fail(step: str, detail: str = "") -> int:
    """Name the family that actually stopped the run."""
    if detail:
        print(detail.strip()[-2500:], flush=True)
    print(f"GATE_FAILED: {step}", flush=True)
    return 1


def count_from(pattern: str, out: str, step: str) -> int | None:
    """Sum every captured group of the count pattern. ZERO IS NOT A PASS."""
    m = re.search(pattern, out)
    if not m:
        print(f"{step}: count pattern matched nothing — a suite whose count "
              f"cannot be read is indistinguishable from one that ran nothing",
              flush=True)
        return None
    total = sum(int(g) for g in m.groups() if g and g.isdigit())
    if total == 0:
        print(f"{step}: the runner reported 0 — a suite that ran nothing is not "
              f"a suite that passed", flush=True)
        return None
    return total


def dotenv_local(keys: list[str]) -> dict[str, str]:
    """Lift named keys from .env.local for families that need them (never printed)."""
    path = ROOT / ".env.local"
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip() in keys and not os.environ.get(k.strip()):
            out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def watchdog(seconds: int, label: str, app=None):
    """Hard deadline for the in-process E2E rung (nothing upstream can interrupt it)."""
    def bark() -> None:
        print(f"E2E_TIMEOUT after {seconds}s — the journey never returned. "
              f"Raise e2e_timeout_s in harness.config.json only if it is "
              f"genuinely this slow.", flush=True)
        print(f"GATE_FAILED: {label}", flush=True)
        try:
            if app is not None:
                app.__exit__(None, None, None)
        except Exception:                                          # noqa: BLE001
            pass
        sys.stdout.flush()
        os._exit(124)

    t = threading.Timer(seconds, bark)
    t.daemon = True
    t.start()
    return t


# --------------------------------------------------------------------- families
def fam_cfg(name: str) -> dict:
    for f in CONFIG["families"]:
        if f["name"] == name:
            return f
    raise KeyError(name)


def run_static() -> bool:
    cfg = fam_cfg("static")
    for step in cfg["steps"]:
        rc, out = run(step["run"], timeout=cfg.get("timeout_s", 600))
        if rc != 0:
            return not fail(f"static:{step['name']}", out)
    COUNTS["static_checks"] = len(cfg["steps"])
    print(f"STATIC_OK checks={len(cfg['steps'])}", flush=True)
    return True


def _jest_fail_files(out: str) -> set[str]:
    return {line.split(None, 1)[1].strip() for line in out.splitlines()
            if line.startswith("FAIL ")}


def run_counted(name: str, floor_key: str,
                extra_env: dict[str, str] | None = None) -> bool:
    cfg = fam_cfg(name)
    rc, out = run(cfg["run"], timeout=cfg.get("timeout_s", 600),
                  extra_env=extra_env)
    # One retry, unit family only, on exactly two shapes — never on an assertion
    # failure inside a file the diff touched, which retrying would only mask.
    # Shape 1: a Jest per-test timeout. Load-sensitive flakes under a saturated gate
    # (weeklyReportScreens ran 0.42s solo, 22s mid-gate) cost a full gate pass + a
    # judge call before the human fix 958a9d5, and that fix protected one file, not
    # the class (evolution rec, lap #15).
    # Shape 2: every failing suite is OUTSIDE this diff's own changed files — a
    # `waitFor()` flake wears the wrapped assertion's error text, never "Exceeded
    # timeout of", so shape 1 cannot see it; disjointness from the diff means the
    # retry cannot mask a regression the diff introduced (evolution rec, lap #22;
    # third sighting lap #24).
    retry_reason = None
    if rc != 0 and name == "unit":
        if "Exceeded timeout of" in out:
            retry_reason = "a Jest per-test timeout, not an assertion"
        else:
            diff_files = set(filter(None, os.environ.get("FACTORY_DIFF_FILES", "").splitlines()))
            fail_files = _jest_fail_files(out)
            if fail_files and diff_files and fail_files.isdisjoint(diff_files):
                retry_reason = (f"{len(fail_files)} failing suite(s) outside this diff's "
                                f"changed files ({sorted(fail_files)}) -- no causal link")
    if retry_reason:
        print(f"{name}: retrying once - failure was {retry_reason} "
              f"(load-sensitive under a saturated gate, not necessarily a regression)",
              flush=True)
        rc, out = run(cfg["run"], timeout=cfg.get("timeout_s", 600),
                      extra_env=extra_env)
    if rc != 0:
        return not fail(name, out)
    n = count_from(cfg["count_pattern"], out, name)
    if n is None:
        return not fail(name, out)
    COUNTS[floor_key] = n
    unit = "fixtures" if name == "fidelity" else "tests"
    print(f"{cfg['marker']} {unit}={n}", flush=True)
    return True


def run_migrations() -> bool:
    """Conformance lint + local replay for migrations added since the base.

    The lint (harness/migration_lint.py) enforces the vox-database-migrations
    procedure — append-only, 00NNN sequential, header line, regenerated index.
    When the range adds migrations, the local emulator is rebuilt with
    `supabase db reset` so every stack-dependent family after this one runs
    against the schema the PR actually ships. No database beyond the local
    emulator is ever touched here; prod apply is permanently human
    (FACTORY_RULES §2.3).
    """
    cfg = fam_cfg("migrations")
    rc, out = run(f'python3 "{HERE}/migration_lint.py"',
                  timeout=cfg.get("timeout_s", 900))
    print(out.strip(), flush=True)   # the markers must land in the gate log
    if rc != 0:
        return not fail("migrations", out)
    if "MIGRATION_LINT_NONE" in out:
        return True
    m = re.search(r"MIGRATION_LINT_OK files=(\d+)", out)
    if m is None:
        return not fail("migrations", out)
    stack_env_vars()   # the reset needs the local stack up
    rc2, out2 = run("supabase db reset", timeout=cfg.get("timeout_s", 900))
    if rc2 != 0:
        return not fail("migrations:replay", out2)
    print(f"MIGRATION_REPLAY_OK files={m.group(1)}", flush=True)
    return True


def run_drizzle() -> bool:
    """Conformance lint for client (Drizzle/SQLite) migrations added since the base.

    The lint (harness/drizzle_lint.py) enforces the local-migration procedure —
    append-only, NNNN sequential, and three-artifact agreement (.sql files,
    meta/_journal.json, migrations.js), so a factory-authored client migration
    is loadable on device, not just present in the tree. No replay: expo-sqlite
    has no host runtime here; the Jest suite exercises the schema. Territory
    expansion (Rick, 2026-08-18), FACTORY_RULES §2.4b.
    """
    cfg = fam_cfg("drizzle")
    rc, out = run(f'python3 "{HERE}/drizzle_lint.py"',
                  timeout=cfg.get("timeout_s", 300))
    print(out.strip(), flush=True)   # the markers must land in the gate log
    if rc != 0:
        return not fail("drizzle", out)
    if "DRIZZLE_LINT_NONE" in out:
        return True
    if re.search(r"DRIZZLE_LINT_OK files=(\d+)", out) is None:
        return not fail("drizzle", out)
    return True


def run_native_compile() -> bool:
    """Simulator compile check for native (Swift/Kotlin) changes in the range.

    The rest of the gate is blind to native code — nothing else compiles Swift —
    so a lap that touches the native modules must prove the app still builds.
    iOS simulator, Debug, signing disabled: no credentials, no device. Runs ONLY
    when the range touches a trigger path (ios/ and android/ are gitignored
    prebuild artifacts, so modules/ and app.config.ts are the real surface);
    every other lap concludes NATIVE_COMPILE_NONE. Territory expansion
    (Rick, 2026-08-18), FACTORY_RULES §2.4c.
    """
    cfg = fam_cfg("native_compile")
    prefixes = tuple(cfg.get("trigger_paths",
                             ["modules/", "app.config.ts"]))
    diff = os.environ.get("FACTORY_DIFF_FILES")
    if diff is None:
        base = None
        for ref in ("origin/develop", "develop"):
            rc, out = run(f"git merge-base HEAD {ref}", timeout=60)
            if rc == 0 and out.strip():
                base = out.strip().splitlines()[-1]
                break
        if base is None:
            return not fail("native_compile",
                            "cannot resolve a base ref to diff against")
        rc, out = run(f"git diff --name-only {base}...HEAD", timeout=60)
        if rc != 0:
            return not fail("native_compile", out)
        files = out.split()
    else:
        files = diff.split()
    touched = sorted({f for f in files if f.startswith(prefixes)})
    if not touched:
        print("NATIVE_COMPILE_NONE", flush=True)
        return True
    print(f"NATIVE_COMPILE_RANGE files={len(touched)}", flush=True)
    rc, out = run("npx expo prebuild --platform ios",
                  timeout=cfg.get("prebuild_timeout_s", 1200))
    if rc != 0:
        return not fail("native_compile:prebuild", out)
    rc, out = run("xcodebuild -workspace ios/VOX.xcworkspace -scheme VOX "
                  "-configuration Debug -sdk iphonesimulator "
                  "-destination 'generic/platform=iOS Simulator' "
                  "CODE_SIGNING_ALLOWED=NO build",
                  timeout=cfg.get("timeout_s", 2400))
    if rc != 0 or "** BUILD SUCCEEDED **" not in out:
        return not fail("native_compile", out)
    print("NATIVE_COMPILE_OK platform=ios-simulator", flush=True)
    return True


def stack_env_vars() -> dict[str, str]:
    sys.path.insert(0, str(HERE))
    from appproc import stack_env                                  # noqa: E402
    env = stack_env(int(CONFIG["app"].get("stack_start_timeout_s", 300)))
    return {"SUPABASE_URL": env["url"],
            "SUPABASE_ANON_KEY": env["anon_key"],
            "SUPABASE_SERVICE_ROLE_KEY": env["service_role_key"]}


def run_deno_integration() -> bool:
    """The Deno live-stack suites (supabase/functions/tests/integration) — dark
    until 2026-08-18 (the gap issues #15/#18/#22 kept recording: the directory
    looked like coverage and nothing executed it). Owns its own functions-serve
    gateway exactly like the e2e family (VoxStack refuses to share with a dev
    serve), then runs the suites with RUN_INTEGRATION=true. Counted;
    floor-tracked as deno_integration_tests.
    """
    cfg = fam_cfg("deno_integration")
    sys.path.insert(0, str(HERE))
    from appproc import VoxStack, AppDidNotStart                   # noqa: E402
    extra = stack_env_vars()
    extra["RUN_INTEGRATION"] = "true"
    extra["NO_COLOR"] = "1"          # ANSI codes would break the count pattern
    # These suites' documented contract is MOCK_MODE=true (pipeline-chain says so
    # in its test names) — the family owns its serve, so it honors that, while the
    # e2e family's serve keeps MOCK_MODE=false for its real-provider journey.
    stack_cfg = copy.deepcopy(CONFIG)
    stack_cfg.setdefault("app", {}).setdefault("serve_env_force", {})
    stack_cfg["app"]["serve_env_force"]["MOCK_MODE"] = "true"
    try:
        with VoxStack(stack_cfg):                                  # prints APP_STARTED
            rc, out = run(cfg["run"], timeout=cfg.get("timeout_s", 900),
                          extra_env=extra)
    except AppDidNotStart as e:
        return not fail("deno_integration:app", str(e))
    n = count_from(cfg["count_pattern"], out, "deno_integration")
    if rc != 0 or n is None:
        return not fail("deno_integration", out)
    COUNTS["deno_integration_tests"] = n
    print(f"{cfg['marker']} tests={n}", flush=True)
    return True


def run_e2e_family() -> bool:
    sys.path.insert(0, str(HERE))
    from appproc import make_driver, AppDidNotStart                # noqa: E402
    from e2e import run_e2e_pipeline, run_e2e_query, Journey       # noqa: E402

    try:
        driver = make_driver(CONFIG)
    except AppDidNotStart as e:
        return not fail("app", str(e))
    try:
        with driver as app:                                        # prints APP_STARTED
            wd = watchdog(int(CONFIG.get("e2e_timeout_s", 900)), "e2e", app)
            ctx = Journey(app)
            try:
                steps = run_e2e_pipeline(app, ctx)
                if steps is None:
                    return not fail("e2e:pipeline")
                COUNTS["e2e_pipeline_steps"] = steps
                print(f"E2E_PIPELINE_PASSED steps={steps}", flush=True)

                steps = run_e2e_query(app, ctx)
                if steps is None:
                    return not fail("e2e:query")
                COUNTS["e2e_query_steps"] = steps
                print(f"E2E_QUERY_PASSED steps={steps}", flush=True)
            finally:
                wd.cancel()
                ctx.teardown()
    except AppDidNotStart as e:
        return not fail("app", str(e))
    return True


def run_holdout() -> bool:
    if not HOLDOUT.exists():
        return not fail("holdout",
                        "HOLDOUT_ABSENT no .factory/holdout/run.py — nothing above "
                        "the independence line ran, and this gate requires it")
    rc, out = run(f"{sys.executable} {HOLDOUT}", timeout=900)
    print(out.strip(), flush=True)
    if rc != 0:
        return not fail("holdout")
    m = re.search(r"HOLDOUT_PASSED scenarios=(\d+) assertions=(\d+)", out)
    if not m:
        return not fail("holdout", "no HOLDOUT_PASSED marker in the holdout output")
    COUNTS["holdout_scenarios"] = int(m.group(1))
    COUNTS["holdout_assertions"] = int(m.group(2))
    return True


def run_compile_eval() -> bool:
    cfg = fam_cfg("compile_eval")
    extra = dotenv_local(cfg.get("env_keys_from_dotenv_local", []))
    result = ROOT / cfg["result_json"]
    # A stale artifact from an earlier run must not vouch for this one.
    result.unlink(missing_ok=True)
    for step in cfg["steps"]:
        rc, out = run(step["run"], timeout=cfg.get("timeout_s", 1800),
                      extra_env=extra)
        if rc != 0:
            return not fail(f"compile_eval:{step['name']}", out)
    if not result.exists():
        return not fail("compile_eval",
                        "gate exited 0 but wrote no result artifact — a verdict "
                        "that cannot be read did not happen")
    # The artifact is an array of per-fixture verdicts:
    # {date, scores:{dim:score}, passes:{dim:bool}, weighted, ...}
    verdicts = json.loads(result.read_text(encoding="utf-8"))
    if not isinstance(verdicts, list) or not verdicts:
        return not fail("compile_eval",
                        f"result artifact is not a verdict list: "
                        f"{str(verdicts)[:200]}")
    dims = len(verdicts[0].get("scores") or {})
    weighted = verdicts[0].get("weighted")
    if dims == 0 or not all(v.get("passes") and all(v["passes"].values())
                            for v in verdicts):
        return not fail("compile_eval",
                        f"result artifact carries a failing or empty verdict: "
                        f"{str(verdicts)[:300]}")
    COUNTS["compile_eval_dims"] = dims
    print(f"COMPILE_EVAL_PASSED dims={dims} weighted={weighted}", flush=True)
    return True


def run_floor() -> bool:
    """The ratchet. Both halves: observed vs floor, and floor(head) vs floor(base)."""
    if not FLOOR_FILE.exists():
        return not fail("floor", "no .factory/locks/floor.json — the gate has no "
                                 "memory of what it used to prove")
    lock = json.loads(FLOOR_FILE.read_text(encoding="utf-8"))
    checked = 0
    for key, floor in (lock.get("exact") or {}).items():
        got = COUNTS.get(key)
        if got is None:
            return not fail("floor", f"{key}: the family never reported a count")
        if got != floor:
            return not fail(
                "floor",
                f"{key}: observed {got}, floor {floor} (exact). If you added "
                f"assertions, raise the floor in the same human commit — the gap "
                f"between observed and floor is exactly how many assertions can "
                f"be deleted with the gate still green")
        checked += 1
    for key, floor in (lock.get("min") or {}).items():
        got = COUNTS.get(key)
        if got is None:
            return not fail("floor", f"{key}: the family never reported a count")
        if got < floor:
            return not fail("floor", f"{key}: observed {got} fell below floor "
                                     f"{floor} — coverage went backwards")
        if got > floor:
            print(f"FLOOR_SLACK {key} observed={got} floor={floor} — "
                  f"deletable-assertion gap; raise the floor", flush=True)
        checked += 1

    base_ref = CONFIG.get("base_ref", "develop")
    rc, base_raw = run(f"git show {base_ref}:.factory/locks/floor.json",
                       timeout=30)
    if rc == 0:
        base = json.loads(base_raw)
        for section in ("exact", "min"):
            for key, base_floor in (base.get(section) or {}).items():
                head_floor = (lock.get(section) or {}).get(key)
                if head_floor is None or head_floor < base_floor:
                    return not fail(
                        "floor",
                        f"{key}: floor lowered vs {base_ref} "
                        f"({base_floor} -> {head_floor}) — deleting the assertion "
                        f"and lowering the number in the same commit is the move "
                        f"this check exists to stop")
    else:
        print(f"FLOOR_BASE_ABSENT no floor.json on {base_ref} yet — "
              f"ratchet half 2 starts at the first commit that carries it",
              flush=True)
    print(f"FLOOR_OK families={checked}", flush=True)
    return True


def run_mutations() -> bool:
    rc, out = run(f"{sys.executable} harness/mutations/run.py", timeout=14400)
    print(out.strip(), flush=True)
    if rc != 0:
        return not fail("mutations")
    return True


# --------------------------------------------------------------------- main
def main() -> int:
    if STOP_FILE.exists():
        reason = STOP_FILE.read_text(encoding="utf-8", errors="replace").strip()
        print(f"FACTORY_STOPPED .factory/STOP is down"
              f"{' — ' + reason if reason else ''}. No rung runs while the stop "
              f"button is pressed; remove the file to resume.", flush=True)
        return 2

    mode = ("quick" if QUICK else
            "partial" if FAMILIES else
            "prove" if PROVE else "full")
    print(f"HARNESS_START mode={mode}", flush=True)

    ladder: list[tuple[str, object]] = [
        ("static", run_static),
        ("unit", lambda: run_counted("unit", "unit_tests")),
        ("ef_unit", lambda: run_counted("ef_unit", "ef_unit_tests")),
        ("fidelity", lambda: run_counted("fidelity", "fidelity_fixtures")),
        ("migrations", run_migrations),
        ("drizzle", run_drizzle),
        ("integration", lambda: run_counted("integration", "integration_tests",
                                            extra_env=stack_env_vars())),
        ("deno_integration", run_deno_integration),
        ("native_compile", run_native_compile),
        ("e2e", run_e2e_family),
        ("holdout", run_holdout),
        ("compile_eval", run_compile_eval),
    ]

    if QUICK:
        selected = [(n, f) for n, f in ladder if fam_cfg(n).get("quick")]
    elif FAMILIES:
        unknown = [n for n in FAMILIES if n not in {n for n, _ in ladder}]
        if unknown:
            return fail("families", f"unknown families: {unknown}")
        selected = [(n, f) for n, f in ladder if n in FAMILIES]
    else:
        selected = ladder

    for name, fn in selected:
        if not fn():
            return 1

    if QUICK:
        print("GATE_OK mode=quick", flush=True)
        return 0
    if FAMILIES:
        print(f"GATE_PARTIAL families={','.join(FAMILIES)} — a partial run can "
              f"fail the gate but never pass it", flush=True)
        return 0

    if not run_floor():
        return 1

    if os.environ.get("FACTORY_IN_MUTATION") == "1":
        print("MUTATIONS_SKIPPED running inside a mutation build", flush=True)
    elif PROVE:
        if not run_mutations():
            return 1
    else:
        print("MUTATIONS_DEFERRED the standing proof runs via "
              "`python3 harness/ci.py --prove` (or harness/mutations/run.py) — "
              "this lap did NOT re-prove the gate can fail", flush=True)

    print(f"GATE_OK mode={'prove' if PROVE else 'full'}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
