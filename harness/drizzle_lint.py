"""Drizzle client-migration conformance lint — the RN half of the migration rung.

Territory expansion (Rick, 2026-08-18): factory laps may now carry local Drizzle/SQLite
migrations (src/db/migrations). This lint makes a factory-authored client migration
indistinguishable in form from a hand-authored one:

  1. append-only: no existing .sql migration modified or deleted (meta/ and
     migrations.js are generated companions and are expected to change);
  2. filename `NNNN_snake_case_name.sql` (drizzle-kit's four-digit convention);
  3. numbers strictly consecutive from the base's highest — never reused, never gapped;
  4. the three artifacts agree: every .sql file has a meta/_journal.json entry whose
     tag matches its basename, journal idx values are 0..N-1 in order, and
     migrations.js imports exactly the journal's tag set (drizzle's runtime walks the
     journal and looks each tag up in migrations.js — a missing member is invisible
     until it crashes on device).

Markers (exactly one concludes a run; factory/gate.sh asserts a conclusion exists
when FACTORY_REQUIRE_DRIZZLE_CONCLUSION=1):
  DRIZZLE_LINT_NONE          — the range adds no client migrations
  DRIZZLE_LINT_OK files=N    — every added migration conforms
  DRIZZLE_LINT_FAIL ...      — one line per violation, exit 1

What this deliberately does NOT do: run migrations (no expo-sqlite outside a device;
the Jest suite exercises the schema) or require regeneration byte-identity for
migrations.js — hand-repair of drizzle-kit snapshot drift is a recorded practice
(.agents/code-reviews/story-10-1, line 142), so agreement is checked structurally.

  python3 harness/drizzle_lint.py [--base <ref>] [--selftest]
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

MIG_DIR = "src/db/migrations"
JOURNAL = f"{MIG_DIR}/meta/_journal.json"
LOADER = f"{MIG_DIR}/migrations.js"
FILENAME_RE = re.compile(r"^(\d{4})_([a-z0-9_]+)\.sql$")
IMPORT_RE = re.compile(r"""import\s+m\d+\s+from\s+['"]\./(.+?)\.sql['"]""")


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
    """Return the violation, or None if `name` is a well-formed drizzle migration filename."""
    if not FILENAME_RE.match(name):
        return (f"{name}: filename must be NNNN_snake_case_name.sql "
                f"(four digits, lowercase snake_case, .sql — drizzle-kit's convention)")
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
            problems.append(f"{name}: number {num:04d} is not after the base's highest "
                            f"({base_max:04d}) — numbers are never reused")
        elif num != expected:
            problems.append(f"{name}: expected {expected:04d} next (base max {base_max:04d} "
                            f"plus the files added before it) — no gaps, no reuse")
        expected = max(expected, num) + 1
    return problems


def check_agreement(sql_tags: set[str], journal_tags: list[str],
                    loader_tags: set[str]) -> list[str]:
    """The .sql files, journal entries, and migrations.js imports must be the same set,
    and journal order must be stable (unique tags)."""
    problems: list[str] = []
    jset = set(journal_tags)
    if len(journal_tags) != len(jset):
        problems.append("meta/_journal.json has duplicate tags")
    for tag in sorted(sql_tags - jset):
        problems.append(f"{tag}.sql has no meta/_journal.json entry — run "
                        f"`npx drizzle-kit generate` (or append the entry) so the "
                        f"runtime can see it")
    for tag in sorted(jset - sql_tags):
        problems.append(f"journal entry '{tag}' has no matching .sql file")
    for tag in sorted(sql_tags - loader_tags):
        problems.append(f"{tag}.sql is not imported by migrations.js — the migration "
                        f"is invisible to the app until migrations.js includes it")
    for tag in sorted(loader_tags - sql_tags):
        problems.append(f"migrations.js imports './{tag}.sql' which does not exist")
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
        print("DRIZZLE_LINT_FAIL cannot resolve a base ref (origin/develop, develop) "
              "to diff against — refusing to conclude anything")
        return 1

    rc, out = sh(["git", "diff", "--name-status", f"{base}..HEAD", "--", MIG_DIR])
    if rc != 0:
        print(f"DRIZZLE_LINT_FAIL git diff failed: {out.strip()[:200]}")
        return 1

    added: list[str] = []
    violations: list[str] = []
    touched = False
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status, path = parts[0], parts[-1]
        name = Path(path).name
        touched = True
        if not name.endswith(".sql"):
            continue  # meta/, migrations.js — generated companions, changes expected
        if status.startswith("A"):
            added.append(name)
        else:
            violations.append(f"{name}: existing client migration was "
                              f"{'deleted' if status.startswith('D') else 'modified'} — "
                              f"src/db/migrations is append-only (FACTORY_RULES §2.4b)")

    if not touched and not violations:
        print("DRIZZLE_LINT_NONE")
        return 0

    for name in added:
        v = check_filename(name)
        if v:
            violations.append(v)

    rc, out = sh(["git", "ls-tree", "-r", "--name-only", base, "--", MIG_DIR])
    base_nums = [int(m.group(1)) for p in out.splitlines()
                 if (m := FILENAME_RE.match(Path(p).name))]
    base_max = max(base_nums) if base_nums else -1
    violations += check_sequence(base_max, added)

    # three-artifact agreement, checked against the working tree as a whole
    sql_tags = {p.stem for p in Path(MIG_DIR).glob("*.sql")}
    try:
        journal = json.loads(Path(JOURNAL).read_text(encoding="utf-8"))
        journal_tags = [e.get("tag", "") for e in journal.get("entries", [])]
        idxs = [e.get("idx") for e in journal.get("entries", [])]
        if idxs != list(range(len(idxs))):
            violations.append("meta/_journal.json idx values are not 0..N-1 in order")
    except (OSError, json.JSONDecodeError) as e:
        journal_tags = []
        violations.append(f"{JOURNAL} unreadable: {e}")
    try:
        loader_tags = set(IMPORT_RE.findall(Path(LOADER).read_text(encoding="utf-8")))
    except OSError as e:
        loader_tags = set()
        violations.append(f"{LOADER} unreadable: {e}")
    violations += check_agreement(sql_tags, journal_tags, loader_tags)

    if violations:
        for v in violations:
            print(f"DRIZZLE_LINT_FAIL {v}")
        return 1

    print(f"DRIZZLE_LINT_OK files={len(added)}")
    return 0


# ---- selftest ----------------------------------------------------------------

def selftest() -> int:
    cases = 0

    def ok(cond: bool, what: str) -> None:
        nonlocal cases
        cases += 1
        if not cond:
            print(f"DRIZZLE_LINT_SELFTEST_FAIL {what}")
            raise SystemExit(1)

    ok(check_filename("0024_add_thing.sql") is None, "well-formed filename accepted")
    ok(check_filename("0024_mighty_omega_flight.sql") is None, "drizzle word-name accepted")
    ok(check_filename("24_add_thing.sql") is not None, "short number rejected")
    ok(check_filename("0024-add-thing.sql") is not None, "kebab-case rejected")
    ok(check_filename("0024_Add_Thing.sql") is not None, "uppercase rejected")
    ok(check_filename("0024_add_thing.txt") is not None, "non-sql rejected")

    ok(check_sequence(23, ["0024_a.sql"]) == [], "next number accepted")
    ok(check_sequence(23, ["0024_a.sql", "0025_b.sql"]) == [], "two consecutive accepted")
    ok(check_sequence(23, ["0026_a.sql"]) != [], "gap rejected")
    ok(check_sequence(23, ["0023_a.sql"]) != [], "reuse rejected")
    ok(check_sequence(23, ["0024_a.sql", "0024_b.sql"]) != [], "duplicate rejected")
    ok(check_sequence(-1, ["0000_a.sql"]) == [], "empty base starts at 0000")

    ok(check_agreement({"0000_a"}, ["0000_a"], {"0000_a"}) == [], "agreement accepted")
    ok(check_agreement({"0000_a"}, [], {"0000_a"}) != [], "missing journal entry rejected")
    ok(check_agreement({"0000_a"}, ["0000_a"], set()) != [], "missing loader import rejected")
    ok(check_agreement({"0000_a"}, ["0000_a", "0001_b"], {"0000_a"}) != [],
       "ghost journal entry rejected")
    ok(check_agreement({"0000_a"}, ["0000_a", "0000_a"], {"0000_a"}) != [],
       "duplicate journal tags rejected")

    print(f"DRIZZLE_LINT_SELFTEST_OK n={cases}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
