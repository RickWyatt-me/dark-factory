#!/usr/bin/env python3
"""MUTATION TESTING — break VOX on purpose and require the gate to notice.

    python3 harness/mutations/run.py                 # the whole defect set
    python3 harness/mutations/run.py --only <id>     # one defect

THE ONLY THING IN THE HARNESS THAT MEASURES THE HARNESS. Everything else answers
"is this build good?"; this answers "would the gate know if it were not?" — and until
it has run, no check in the ladder has ever been shown to be able to fail.

VOX ADAPTATIONS versus the template (templates/harness/mutations/run.py), and why:

  * IN-PLACE, NOT A REPO COPY. The template copies the repo to a temp dir per defect
    and runs the gate there. VOX's app-under-test is the LOCAL SUPABASE STACK plus
    `supabase functions serve` — a single stateful instance keyed to this directory,
    plus a multi-GB node_modules. A per-defect copy can neither carry the stack nor
    afford the copy. So each defect is applied to the working tree, the gate runs
    here, and the exact original bytes are restored in a `finally`. The runner
    REFUSES to start if any target file is already dirty in git, so a crash cannot
    silently leave a mutation behind — and it re-verifies restoration afterwards.

  * TARGETED RUNGS, WITH ESCALATION. The template re-runs the full gate per defect.
    VOX's full gate includes a paid compile eval and a multi-minute E2E; N defects x
    full gate is not a set anyone re-runs, and a mutation set nobody re-runs stops
    covering new behaviour without announcing it. Each defect declares the rung
    families expected to catch it (`catch`); the runner runs THOSE first. Only if
    they pass does it escalate to the full remaining ladder before declaring
    ESCAPED — so a CAUGHT verdict is cheap and an ESCAPED verdict is honest.
    (Catching by any family implies the full gate goes red: ci.py fails on the
    first red rung, and the families run are a subset of the full ladder.)

Emits MUTATIONS_TOTAL / MUTATIONS_CAUGHT / MUTATIONS_NOT_INJECTED and MUTATIONS_OK
only when caught == total and nothing failed to inject. NOT_INJECTED is a failure:
a defect whose anchor moved tested nothing, and a set that silently stops injecting
reports a perfect score for doing nothing at all.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
DEFECTS = HERE / "defects.json"

ONLY = None
if "--only" in sys.argv:
    ONLY = sys.argv[sys.argv.index("--only") + 1]


def sh(*argv: str, timeout: int = 60) -> tuple[int, str]:
    p = subprocess.run(list(argv), cwd=ROOT, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def gate(families: list[str] | None, timeout: int) -> tuple[int, str]:
    """Run the gate (or a family subset) with recursion disabled."""
    cmd = [sys.executable, "harness/ci.py"]
    if families:
        cmd += ["--families", ",".join(families)]
    env = dict(os.environ, FACTORY_IN_MUTATION="1")
    p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True,
                       encoding="utf-8", errors="replace", timeout=timeout)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def catching_rung(out: str) -> str:
    for line in out.splitlines():
        if line.startswith("GATE_FAILED:"):
            return line.split(":", 1)[1].strip()
    return "gate"


def main() -> int:
    if not DEFECTS.exists():
        print("MUTATIONS_ABSENT no defects.json next to this script", flush=True)
        return 1

    defects = json.loads(DEFECTS.read_text(encoding="utf-8"))["defects"]
    if ONLY:
        defects = [d for d in defects if d["id"] == ONLY]
        if not defects:
            print(f"MUTATIONS_ABSENT no defect with id {ONLY!r}", flush=True)
            return 1

    # PRE-FLIGHT: snapshot the git state of every target. The baseline the runner
    # restores to is the CURRENT tree (uncommitted work included — the gate judges
    # what is here, not what was committed); what must hold is that this script
    # leaves that state byte-identical. A crash mid-run is caught by the per-defect
    # restore verify below plus the post-run comparison against this snapshot.
    targets = sorted({d["file"] for d in defects})
    rc, before = sh("git", "status", "--porcelain", "--", *targets)
    if rc != 0:
        print(f"MUTATIONS_ABORTED git status failed: {before[-500:]}", flush=True)
        return 1
    if before.strip():
        print("MUTATION_NOTE some targets carry uncommitted changes — the runner "
              "tests and restores the tree AS IT IS:", flush=True)
        print(before.rstrip(), flush=True)

    total = caught = not_injected = 0
    print("MUTATION_START mode=in-place", flush=True)

    for d in defects:
        total += 1
        target = ROOT / d["file"]
        if not target.exists():
            not_injected += 1
            print(f"  NOT_INJECTED  {d['id']:<44} file missing: {d['file']}", flush=True)
            continue
        original = target.read_bytes()
        body = original.decode("utf-8")
        if d["find"] not in body:
            not_injected += 1
            print(f"  NOT_INJECTED  {d['id']:<44} anchor not found in {d['file']}",
                  flush=True)
            continue

        try:
            target.write_text(body.replace(d["find"], d["replace"], 1),
                              encoding="utf-8")
            fams = d.get("catch") or []
            rc, out = gate(fams, timeout=int(d.get("timeout_s", 1800)))
            if rc == 0 and fams:
                # The expected family missed. Escalate to the full remaining ladder
                # before calling it an escape — a defect caught by ANY rung is caught.
                print(f"  ESCALATING    {d['id']:<44} expected {'+'.join(fams)} "
                      f"missed; running the full ladder", flush=True)
                rc, out = gate(None, timeout=3600)
            if rc != 0:
                caught += 1
                print(f"  CAUGHT        {d['id']:<44} by {catching_rung(out)}",
                      flush=True)
            else:
                print(f"  ESCAPED       {d['id']:<44} <-- {d['why']}", flush=True)
        finally:
            target.write_bytes(original)

        # Verify restoration — a mutated tree after this script is worse than any bug.
        if target.read_bytes() != original:
            print(f"MUTATIONS_ABORTED could not restore {d['file']}", flush=True)
            return 1

    rc, after = sh("git", "status", "--porcelain", "--", *targets)
    if after != before:
        print("MUTATIONS_ABORTED target state changed across the run:", flush=True)
        print(f"before:\n{before}\nafter:\n{after}", flush=True)
        return 1

    print(f"MUTATIONS_TOTAL={total}", flush=True)
    print(f"MUTATIONS_CAUGHT={caught}", flush=True)
    print(f"MUTATIONS_NOT_INJECTED={not_injected}", flush=True)
    if caught == total and not_injected == 0:
        print("MUTATIONS_OK", flush=True)
        return 0
    print("MUTATIONS_FAILED — every escaped defect is a class of bug that can "
          "currently merge unreviewed", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
