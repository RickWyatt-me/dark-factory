#!/usr/bin/env python3
"""Rung 1 of the evolution auto-apply channel (FACTORY_RULES 9b) - deterministic.

The evolution loop proposes; this policy decides which proposals are even ELIGIBLE
for the judged auto-apply channel, and verifies an applied edit deterministically
before the independent judge ever sees it. Everything else in RECOMMENDATIONS.md
stays a human commit (9a), forever:

  ELIGIBLE:   Mechanism is exactly one file under factory/prompts/*.md, the block
              carries a ready-to-apply Change, and its status line is exactly
              "- [ ] proposed".
  THE FLOOR:  everything else - the gate (harness/**), the guard, the runner, the
              orchestrator, governance, the holdout, and BOTH special prompt dirs
              (factory/db-apply-prompts/**, factory/evolve-apply-prompts/**,
              factory/evolve-prompts/**): the channel must never tune its own judge,
              the DB judge, or its own proposer. Enforced by construction - the
              eligibility pattern matches factory/prompts/<name>.md and nothing else.

Post-apply checks (--check): the edited prompt may not introduce a placeholder the
runner does not render ({{issue_number}} was the first live output's runner-breaking
scar - the gate this file exists for), may not shrink to nothing, and the changed
line count is capped (a 9b edit is a tweak, not a rewrite).

  evolve_apply_policy.py --list                     eligible pending blocks, JSON
  evolve_apply_policy.py --check OLD NEW CHANGED    verify an applied edit
  evolve_apply_policy.py --mark LINE NOTE           rewrite a block's status line
  evolve_apply_policy.py --selftest
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

RECS = Path(".factory/evolution/RECOMMENDATIONS.md")

# Every {{token}} run-workflow.sh's render step substitutes (the sed block, ~line 259).
# A token in an edited prompt outside this set AND outside the file's own pre-edit set
# survives rendering as literal braces - a prompt that lies. Keep in lockstep with the
# runner; the selftest pins the set's membership semantics, not its contents.
RENDER_SET = {"issue", "issue_id", "issue_ref", "run", "branch", "base", "prfile",
              "attempts", "rundir", "findings", "gatelog", "quick"}

ELIGIBLE_MECH = re.compile(r"^prompt:(factory/prompts/[a-z0-9_-]+\.md)$")
STATUS_PENDING = "- [ ] proposed"
DEFAULT_DIFF_CAP = 40


def tokens(text: str) -> set[str]:
    return set(re.findall(r"\{\{([a-z_]+)\}\}", text))


def parse_blocks(text: str) -> list[dict]:
    """Split RECOMMENDATIONS.md into '## ' blocks with 1-based line spans."""
    lines = text.splitlines()
    starts = [i for i, l in enumerate(lines) if l.startswith("## ")]
    blocks = []
    for idx, s in enumerate(starts):
        e = starts[idx + 1] if idx + 1 < len(starts) else len(lines)
        body = lines[s:e]
        mech = next((re.sub(r"^- \*\*Mechanism:\*\*\s*", "", l).strip()
                     for l in body if l.startswith("- **Mechanism:**")), "")
        status = next((l.strip() for l in body if l.strip().startswith("- [")), "")
        blocks.append({
            "title": lines[s][3:].strip(),
            "start_line": s + 1, "end_line": e,
            "mechanism": mech, "status": status,
            "has_change": any("**Change (ready to apply):**" in l for l in body),
        })
    return blocks


def eligible(block: dict, repo_root: Path = Path(".")) -> str | None:
    """Return the target prompt path if the block may enter the 9b channel."""
    m = ELIGIBLE_MECH.match(block["mechanism"])
    if not m:
        return None
    if block["status"] != STATUS_PENDING:      # exact - a parked-note suffix disqualifies
        return None
    if not block["has_change"]:
        return None
    target = m.group(1)
    if not (repo_root / target).is_file():
        return None
    return target


def check_apply(old: str, new: str, changed_lines: int,
                cap: int = DEFAULT_DIFF_CAP) -> list[str]:
    """Deterministic violations in an applied edit; empty list = pass to the judge."""
    problems = []
    stray = tokens(new) - tokens(old) - RENDER_SET
    if stray:
        problems.append(f"introduces unrendered placeholder(s): {sorted(stray)}")
    if not new.strip():
        problems.append("the edited prompt is empty")
    if len(new) < len(old) // 2:
        problems.append(f"the prompt shrank from {len(old)} to {len(new)} chars - "
                        "a 9b edit adds or adjusts, it does not gut")
    if changed_lines > cap:
        problems.append(f"{changed_lines} changed lines exceeds the 9b cap of {cap}")
    return problems


def mark(start_line: int, note: str, path: Path = RECS) -> bool:
    """Replace the block's exact pending status line with `note`. False if absent."""
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    i = start_line - 1
    end = next((j for j in range(i + 1, len(lines)) if lines[j].startswith("## ")),
               len(lines))
    for j in range(i, end):
        if lines[j].rstrip("\n") == STATUS_PENDING:
            lines[j] = note.rstrip("\n") + "\n"
            path.write_text("".join(lines), encoding="utf-8")
            return True
    return False


def selftest() -> int:
    ok = 0

    def t(name, cond):
        nonlocal ok
        if not cond:
            print(f"SELFTEST FAIL: {name}")
            sys.exit(1)
        ok += 1

    md = (
        "## 2026-08-18 · gh:issue:24 · judge tool hint\n"
        "- **Mechanism:** prompt:factory/prompts/judge.md\n"
        "- **Problem:** x\n"
        "- **Change (ready to apply):**\n  text\n"
        "- [ ] proposed\n"
        "## 2026-08-18 · gh:issue:22 · gate retry\n"
        "- **Mechanism:** gate (harness/ci.py run_counted) + factory/run-workflow.sh\n"
        "- **Change (ready to apply):**\n  code\n"
        "- [ ] proposed\n"
        "## 2026-08-17 · gh:issue:17 · already done\n"
        "- **Mechanism:** prompt:factory/prompts/review.md\n"
        "- **Change (ready to apply):**\n  text\n"
        "- [x] applied 2026-08-17 (Rick's go)\n"
        "## 2026-08-18 · gh:issue:9 · parked earlier\n"
        "- **Mechanism:** prompt:factory/prompts/plan.md\n"
        "- **Change (ready to apply):**\n  text\n"
        "- [ ] proposed (auto-apply parked 2026-08-18: human review)\n"
        "## 2026-08-18 · gh:issue:9 · self-tuning attempt\n"
        "- **Mechanism:** prompt:factory/evolve-apply-prompts/judge.md\n"
        "- **Change (ready to apply):**\n  text\n"
        "- [ ] proposed\n"
        "## 2026-08-18 · gh:issue:9 · no snippet\n"
        "- **Mechanism:** prompt:factory/prompts/prime.md\n"
        "- [ ] proposed\n"
    )
    b = parse_blocks(md)
    t("six blocks parsed", len(b) == 6)
    root = Path(".")
    t("prompt mech + pending + snippet -> eligible",
      eligible(b[0], root) == "factory/prompts/judge.md")
    t("compound gate mechanism -> floor", eligible(b[1], root) is None)
    t("already applied -> not pending", eligible(b[2], root) is None)
    t("parked-note suffix -> not pending", eligible(b[3], root) is None)
    t("evolve-apply's own judge -> floor by construction", eligible(b[4], root) is None)
    t("no ready-to-apply snippet -> ineligible", eligible(b[5], root) is None)
    t("missing target file -> ineligible",
      eligible({"mechanism": "prompt:factory/prompts/nonexistent.md",
                "status": STATUS_PENDING, "has_change": True}, root) is None)

    old = "Use {{rundir}} and {{base}}.\nLine.\nMore.\nEven more prompt body here.\n"
    t("render-set token ok", check_apply(old, old + "See {{branch}}.\n", 1) == [])
    t("pre-existing custom token survives",
      check_apply("keep {{custom_x}}\nbody body body\n",
                  "keep {{custom_x}} still\nbody body body\n", 1) == [])
    bad = check_apply(old, old + "read {{issue_number}}\n", 1)
    t("unknown placeholder flagged", any("issue_number" in p for p in bad))
    t("empty result flagged", any("empty" in p for p in check_apply(old, "  ", 1)))
    t("gutted prompt flagged",
      any("shrank" in p for p in check_apply(old * 10, "short\n", 3)))
    t("diff cap flagged", any("cap" in p for p in check_apply(old, old + "x\n", 41)))
    t("cap boundary passes", check_apply(old, old + "x\n", 40) == [])

    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as f:
        f.write(md)
        tmp = Path(f.name)
    t("mark rewrites the exact pending line",
      mark(1, "- [x] auto-applied 2026-08-18 (9b)", tmp)
      and "- [x] auto-applied 2026-08-18 (9b)" in tmp.read_text())
    t("mark is idempotent-safe (second call finds nothing)",
      mark(1, "- [x] again", tmp) is False)
    t("mark stays inside its block (block 2 still pending)",
      STATUS_PENDING in tmp.read_text())
    tmp.unlink()

    print(f"SELFTEST OK cases={ok}")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 1
    if args[0] == "--selftest":
        return selftest()
    if args[0] == "--list":
        blocks = parse_blocks(RECS.read_text(encoding="utf-8")) if RECS.exists() else []
        out = [{"title": b["title"], "start_line": b["start_line"], "file": f}
               for b in blocks if (f := eligible(b))]
        print(json.dumps(out))
        return 0
    if args[0] == "--check" and len(args) == 4:
        problems = check_apply(Path(args[1]).read_text(encoding="utf-8"),
                               Path(args[2]).read_text(encoding="utf-8"),
                               int(args[3]))
        if problems:
            for p in problems:
                print(f"APPLY_CHECK_VIOLATION: {p}")
            return 1
        print("APPLY_CHECK_OK")
        return 0
    if args[0] == "--mark" and len(args) == 3:
        if mark(int(args[1]), args[2]):
            print("MARKED")
            return 0
        print("MARK_FAILED: no exact pending status line in that block")
        return 1
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
