"""Migration conformance lint — the machine-checked half of the vox-database-migrations skill.

Validates every migration ADDED since the base against the procedure this repo has
always used (.claude/skills/vox-database-migrations/SKILL.md), so a factory-authored
migration is indistinguishable in form from a hand-authored one:

  1. append-only: no existing migration file modified or deleted (MIGRATIONS.md exempt);
  2. filename `00NNN_snake_case_name.sql`;
  3. numbers strictly consecutive from the base's highest — never reused, never gapped;
  4. line 1 is the index header `-- 00NNN | YYYY-MM-DD | description`, number matching
     the filename, date real, description substantive;
  5. MIGRATIONS.md was regenerated and committed (`node scripts/gen-migrations-index.mjs`
     reproduces it byte-identically — the index is generated, never hand-edited).

Markers (exactly one concludes a run; factory/gate.sh asserts a conclusion exists):
  MIGRATION_LINT_NONE            — the range adds no migrations
  MIGRATION_LINT_OK files=N      — every added migration conforms
  MIGRATION_LINT_FAIL ...        — one line per violation, exit 1

What this deliberately does NOT do: touch any database. Local replay is ci.py's
`migrations` family (supabase db reset); production apply is permanently human
(FACTORY_RULES §2.3) via MCP apply_migration per the skill.

  python3 harness/migration_lint.py [--base <ref>] [--selftest]
"""
from __future__ import annotations

import datetime
import re
import subprocess
import sys
from pathlib import Path

MIG_DIR = "supabase/migrations"
INDEX = f"{MIG_DIR}/MIGRATIONS.md"
GEN = "node scripts/gen-migrations-index.mjs"
FILENAME_RE = re.compile(r"^(\d{5})_([a-z0-9_]+)\.sql$")
HEADER_RE = re.compile(r"^-- (\d{5}) \| (\d{4}-\d{2}-\d{2}) \| (.+)$")
MIN_DESC = 10


def sh(cmd: list[str]) -> tuple[int, str]:
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    return p.returncode, (p.stdout + p.stderr)


def resolve_base(explicit: str | None) -> str | None:
    for ref in ([explicit] if explicit else []) + ["origin/develop", "develop"]:
        if ref and sh(["git", "rev-parse", "--verify", "--quiet", ref])[0] == 0:
            rc, out = sh(["git", "merge-base", "HEAD", ref])
            if rc == 0 and out.strip():
                return out.strip()
    return None


# ---- pure validators (selftest targets — no git, no filesystem) -------------

def check_filename(name: str) -> str | None:
    """Return the violation, or None if `name` is a well-formed migration filename."""
    if not FILENAME_RE.match(name):
        return (f"{name}: filename must be 00NNN_snake_case_name.sql "
                f"(five digits, lowercase snake_case, .sql)")
    return None


def check_header(name: str, first_line: str) -> str | None:
    """Return the violation, or None if line 1 is the required index header."""
    m = HEADER_RE.match(first_line.rstrip("\n"))
    if not m:
        return (f"{name}: line 1 must be the index header "
                f"'-- 00NNN | YYYY-MM-DD | description' (got: {first_line.strip()[:80]!r})")
    num, date, desc = m.groups()
    fname_num = FILENAME_RE.match(name)
    if fname_num and num != fname_num.group(1):
        return f"{name}: header number {num} does not match the filename's {fname_num.group(1)}"
    try:
        datetime.date.fromisoformat(date)
    except ValueError:
        return f"{name}: header date {date} is not a real date"
    if len(desc.strip()) < MIN_DESC:
        return (f"{name}: header description is {len(desc.strip())} chars — say what the "
                f"migration does (objects touched), not less than {MIN_DESC} chars")
    return None


def check_sequence(base_max: int, added_names: list[str]) -> list[str]:
    """Added numbers must be base_max+1, +2, ... — consecutive, no reuse, no gaps."""
    nums = []
    for n in added_names:
        m = FILENAME_RE.match(n)
        if m:
            nums.append((int(m.group(1)), n))
    problems: list[str] = []
    expected = base_max + 1
    for num, name in sorted(nums):
        if num <= base_max:
            problems.append(f"{name}: number {num:05d} is not after the base's highest "
                            f"({base_max:05d}) — numbers are never reused")
        elif num != expected:
            problems.append(f"{name}: expected {expected:05d} next (base max {base_max:05d} "
                            f"plus the files added before it) — no gaps, no reuse")
        expected = max(expected, num) + 1
    return problems


# ---- the run ----------------------------------------------------------------

def main(argv: list[str]) -> int:
    if "--selftest" in argv:
        return selftest()

    base_arg = None
    if "--base" in argv:
        base_arg = argv[argv.index("--base") + 1]
    base = resolve_base(base_arg)
    if base is None:
        print("MIGRATION_LINT_FAIL cannot resolve a base ref (origin/develop, develop) "
              "to diff against — refusing to conclude anything")
        return 1

    rc, out = sh(["git", "diff", "--name-status", f"{base}..HEAD", "--", MIG_DIR])
    if rc != 0:
        print(f"MIGRATION_LINT_FAIL git diff failed: {out.strip()[:200]}")
        return 1

    added: list[str] = []
    violations: list[str] = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status, path = parts[0], parts[-1]
        name = Path(path).name
        if name == "MIGRATIONS.md":
            continue
        if status.startswith("A"):
            added.append(name)
        else:
            violations.append(f"{name}: existing migration file was "
                              f"{'deleted' if status.startswith('D') else 'modified'} — "
                              f"supabase/migrations is append-only (FACTORY_RULES §2.4)")

    if not added and not violations:
        print("MIGRATION_LINT_NONE")
        return 0

    for name in added:
        v = check_filename(name)
        if v:
            violations.append(v)

    rc, out = sh(["git", "ls-tree", "-r", "--name-only", base, "--", MIG_DIR])
    base_nums = [int(m.group(1)) for p in out.splitlines()
                 if (m := FILENAME_RE.match(Path(p).name))]
    base_max = max(base_nums) if base_nums else 0
    violations += check_sequence(base_max, added)

    for name in added:
        path = Path(MIG_DIR) / name
        if not path.is_file():
            violations.append(f"{name}: added in the range but absent from the tree")
            continue
        first = path.open(encoding="utf-8", errors="replace").readline()
        v = check_header(name, first)
        if v:
            violations.append(v)

    if added:
        index_path = Path(INDEX)
        if not index_path.is_file():
            violations.append(f"{INDEX} missing — run `{GEN}` and commit it")
        else:
            original = index_path.read_bytes()
            try:
                rc, out = sh(GEN.split())
                regenerated = index_path.read_bytes()
            finally:
                index_path.write_bytes(original)
            if rc != 0:
                violations.append(f"index generator failed: {out.strip()[:200]}")
            elif regenerated != original:
                violations.append(f"{INDEX} is stale — the committed index does not match "
                                  f"`{GEN}`'s output. Regenerate and commit it; never "
                                  f"hand-edit it.")

    if violations:
        for v in violations:
            print(f"MIGRATION_LINT_FAIL {v}")
        return 1

    print(f"MIGRATION_LINT_OK files={len(added)}")
    return 0


# ---- selftest ----------------------------------------------------------------

def selftest() -> int:
    cases = 0

    def ok(cond: bool, what: str) -> None:
        nonlocal cases
        cases += 1
        if not cond:
            print(f"MIGRATION_LINT_SELFTEST_FAIL {what}")
            raise SystemExit(1)

    ok(check_filename("00169_add_thing.sql") is None, "well-formed filename accepted")
    ok(check_filename("169_add_thing.sql") is not None, "short number rejected")
    ok(check_filename("00169-add-thing.sql") is not None, "kebab-case rejected")
    ok(check_filename("00169_Add_Thing.sql") is not None, "uppercase rejected")
    ok(check_filename("00169_add_thing.txt") is not None, "non-sql rejected")

    good = "-- 00169 | 2026-08-17 | add vox.things with owner RLS and idx_things_owner"
    ok(check_header("00169_add_thing.sql", good) is None, "well-formed header accepted")
    ok(check_header("00169_add_thing.sql", "CREATE TABLE x;") is not None,
       "missing header rejected")
    ok(check_header("00169_add_thing.sql",
                    "-- 00168 | 2026-08-17 | add vox.things table etc") is not None,
       "number mismatch rejected")
    ok(check_header("00169_add_thing.sql",
                    "-- 00169 | 2026-13-40 | add vox.things table etc") is not None,
       "impossible date rejected")
    ok(check_header("00169_add_thing.sql", "-- 00169 | 2026-08-17 | x") is not None,
       "empty description rejected")

    ok(check_sequence(168, ["00169_a.sql"]) == [], "next number accepted")
    ok(check_sequence(168, ["00169_a.sql", "00170_b.sql"]) == [],
       "two consecutive accepted")
    ok(check_sequence(168, ["00171_a.sql"]) != [], "gap rejected")
    ok(check_sequence(168, ["00168_a.sql"]) != [], "reuse rejected")
    ok(check_sequence(168, ["00169_a.sql", "00169_b.sql"]) != [], "duplicate rejected")

    print(f"MIGRATION_LINT_SELFTEST_OK n={cases}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
