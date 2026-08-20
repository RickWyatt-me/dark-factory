"""Protected paths, size cap, and the append-only migration rule. Structural, not prompted.

FACTORY_RULES.md 5, 5a, 6 and 2. This runs BEFORE any other evaluation, because a change
that can edit the rulebook must not be judged against the edited rulebook.

Usage:
    python3 factory/guard.py [--base <ref>] [--head <ref>]

Defaults to comparing the working tree against the base branch. Exits:
    0  PROTECTED_OK
    1  PROTECTED_VIOLATION   a protected file was touched -- auto-reject, no fix attempt
    2  GUARD_ERROR           the guard could not run, which is NOT a pass

Exit code 2 matters more than it looks. A guard that cannot determine the diff must fail
closed. Failing open here would mean "we could not check, so we merged", which is the
same class of mistake as counting a skipped check as a passed one.
"""
from __future__ import annotations
import fnmatch
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# FACTORY_RULES.md 5, verbatim, kept here IN CODE rather than in a data file the factory
# could plausibly be asked to edit. factory/** is itself protected, so this list is
# protected by the rule it defines. fnmatch's * crosses path separators, so "factory/*"
# covers everything below factory/, nested directories included.
PROTECTED = [
    # Governance -- the constitution. The agent cannot amend the rules it is judged by.
    "MISSION.md", "FACTORY_RULES.md", "CLAUDE.md", "AGENTS.md", "FACTORY.md",
    # The PRD the mission was distilled from.
    "docs/factory/vox.prd.md", "docs/*.prd.md",
    # Factory machinery: this runner, the Phase B validation harness (its mutation set
    # included), the locks (the ratchet floor a human chose), and the holdout (the
    # assertions the builder does not get to weaken -- and, per §9, never gets to READ;
    # the read-block is the runner's --disallowedTools, this is the write-block).
    "factory/*", "harness/*",
    ".factory/locks/*", ".factory/holdout/*",
    # The frozen predecessor (program decision D4) and the human program record.
    ".agents/harness/*", ".agents/harness.binding.yaml", ".agents/dark-factory/*",
    # Migrations: supabase/migrations/** is APPEND-ONLY (see APPEND_ONLY below -- new
    # sequential files via the skill procedure are allowed; edits to applied files never
    # are). seed.sql is flatly protected.
    "supabase/seed.sql",
    # CI and repo config.
    ".github/*",
    # Secrets and env (FACTORY_RULES.md 5a).
    ".env", ".env.*", "*.local", "*credential*", "*secret*", "*.pem", "*.p8",
    "service-account.json",
    # Payment surfaces -- Stripe is on the irreversible list (§7.3).
    "supabase/functions/fn-create-checkout/*",
    "supabase/functions/fn-stripe-webhook/*",
    # Auth/privilege invariants.
    "supabase/functions/_shared/auth*",
    "supabase/functions/function-allowlist.json",
]

# APPEND-ONLY paths: a NEW file here is allowed (that is how schema changes ship --
# sequential files per the vox-database-migrations skill, applied to the local emulator
# only). MODIFYING, DELETING or RENAMING an existing file here is a violation: the
# migration history is the record, and an edited applied migration is a rewritten record.
# MIGRATIONS.md is the generated index and must be able to change alongside a new file.
APPEND_ONLY = ["supabase/migrations/*"]
APPEND_ONLY_EXEMPT = ["supabase/migrations/MIGRATIONS.md"]

# No whole-category binary ban for VOX -- the harness carries a committed audio fixture
# on purpose. The size cap and protected list carry the load.
BINARY_ASSETS: list[str] = []

SIZE_CAP = int(os.environ.get("FACTORY_SIZE_CAP", "500"))
SIZE_EXEMPT = [".factory/runs/*", ".factory/locks/*"]

# THE SCOPE LEASH -- a file count, not a line count, on purpose. The failure it catches
# is a node growing a six-file PR into eleven with five one-line "while I was in here"
# edits, well under the line cap the whole way.
FILE_CAP = int(os.environ.get("FACTORY_FILE_CAP", "12"))


def git(*args: str) -> tuple[int, str]:
    p = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, text=True)
    return p.returncode, p.stdout.strip()


def base_ref(explicit: str | None) -> str | None:
    if explicit:
        return explicit
    # The factory's base is develop (program decision D2), read from the environment so
    # config.sh stays the one file that knows it. origin/HEAD points at main on this
    # repo, which is exactly the branch the factory never targets.
    configured = os.environ.get("FACTORY_BASE_BRANCH", "develop")
    for cand in (configured, f"origin/{configured}", "origin/HEAD", "main", "master"):
        rc, out = git("rev-parse", "--verify", "--quiet", cand)
        if rc == 0 and out:
            return cand
    return None


def matches(path: str, patterns: list[str]) -> bool:
    p = path.replace("\\", "/")
    return any(fnmatch.fnmatch(p, pat) or fnmatch.fnmatch(os.path.basename(p), pat)
               for pat in patterns)


def main() -> int:
    argv = sys.argv[1:]
    base = base_ref(argv[argv.index("--base") + 1] if "--base" in argv else None)
    head = argv[argv.index("--head") + 1] if "--head" in argv else None

    if base is None:
        print("GUARD_ERROR: no base branch found. The guard fails closed: a diff that "
              "cannot be computed is not a diff that was checked.")
        return 2

    # THREE dots, always. `git diff main` compares the two TIPS, so a branch cut before
    # the base moved reports the base's later commits as though this branch had made
    # them. `base...HEAD` compares against the MERGE BASE: what this branch changed.
    rng = f"{base}...{head}" if head else f"{base}...HEAD"

    # name-status rather than name-only, because the append-only rule needs to know
    # WHETHER a path was added or modified, not merely that it changed.
    rc, out = git("diff", "--name-status", rng)
    if rc != 0:
        print(f"GUARD_ERROR: git diff {rng} failed. Failing closed.")
        return 2

    # path -> one status letter. A rename or copy is a delete of the old path and an add
    # of the new one, which is exactly how the append-only rule needs to see it.
    status: dict[str, str] = {}
    for row in out.splitlines():
        parts = row.split("\t")
        if not parts or not parts[0].strip():
            continue
        st = parts[0].strip()[0]
        if st in ("R", "C") and len(parts) == 3:
            if st == "R":
                status[parts[1]] = "D"
            status[parts[2]] = "A"
        elif len(parts) >= 2:
            status[parts[1]] = st
    changed = list(status)

    # A three-dot diff only sees COMMITTED work. In the workflow the guard runs after the
    # commit step; anything run by hand on a dirty tree would otherwise be checked against
    # nothing and print a confident PROTECTED_OK.
    if not head:
        # `-uall`, and it is not optional: the default collapses an untracked DIRECTORY
        # into a single entry, so a node creating a whole new directory reported one
        # changed file and none of its contents were checked individually.
        rc, dirty = git("status", "--porcelain", "--untracked-files=all")
        if rc != 0:
            print("GUARD_ERROR: git status failed. Failing closed.")
            return 2
        for row in dirty.splitlines():
            # porcelain is exactly two status columns, then the path.
            code = row[:2]
            path = row[2:].lstrip().strip('"')
            if " -> " in path:                      # a rename: check the destination
                path = path.split(" -> ", 1)[1]
            if path and path not in status:
                status[path] = "A" if "?" in code else code.strip()[:1] or "M"
                changed.append(path)

    rc, stat = git("diff", "--numstat", rng)
    lines = 0
    if rc == 0:
        for row in stat.splitlines():
            parts = row.split("\t")
            if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
                if not matches(parts[2], SIZE_EXEMPT):
                    lines += int(parts[0]) + int(parts[1])

    print(f"GUARD_START range={rng} files={len(changed)} lines={lines}")

    violations: list[tuple[str, str]] = []
    for f in changed:
        if matches(f, PROTECTED):
            violations.append((f, "protected file (FACTORY_RULES.md 5)"))
        elif matches(f, APPEND_ONLY) and not matches(f, APPEND_ONLY_EXEMPT):
            if status.get(f, "M") != "A":
                violations.append(
                    (f, "append-only path modified or removed (FACTORY_RULES.md 2.4: "
                        "supabase/migrations/ takes new sequential files only)"))
        elif matches(f, BINARY_ASSETS):
            violations.append((f, "banned file category (see BINARY_ASSETS)"))

    for f in changed:
        print(f"  {'BLOCK' if any(v[0] == f for v in violations) else 'ok   '}  {f}")

    print(f"GUARD_FILES_CHECKED={len(changed)}")

    if violations:
        print(f"PROTECTED_VIOLATION={len(violations)}")
        for f, why in violations:
            print(f"  {f}: {why}")
        print("Auto-reject, no fix attempt (FACTORY_RULES.md 6). Needing one of these "
              "touched means the scope was misunderstood, which is a triage bug rather "
              "than a code bug -- escalate to needs-human.")
        return 1

    scoped = [f for f in changed if not matches(f, SIZE_EXEMPT)]
    if FILE_CAP and len(scoped) > FILE_CAP:
        print(f"SCOPE_VIOLATION: {len(scoped)} files changed, cap is {FILE_CAP}. "
              "A node that can edit outside its own scope will grow the PR and introduce "
              "a bug in a file nobody asked it to touch. Split the work into a sub-issue.")
        return 1

    if lines > SIZE_CAP:
        print(f"SIZE_VIOLATION: {lines} lines changed, cap is {SIZE_CAP} "
              "(FACTORY_RULES.md 2). Split the work into a sub-issue rather than "
              "shipping something nobody could review even in principle.")
        return 1

    print("PROTECTED_OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
