# Working notes — dark-factory export

One lesson per note. Only things git history can't show.

- **No raw governance copies in this repo, ever.** First draft of
  `scripts/sync-from-source.sh` kept `upstream/MISSION.md` etc. as reference
  copies for template-drift diffing. That silently violates the export
  boundary (the source MISSION *is* product content). Replaced with
  hash-tracking in ENGINE_PIN: drift is detected by blob hash, re-derivation
  happens against the source repo, content never lands here. Any future
  convenience that involves copying a source governance file in should get
  the same answer.

- **Creating the GitHub repo needs the owner.** The export session's
  permission classifier blocked `gh repo create` (2026-08-20). Everything
  was built locally; the create + first push is a one-command step for the
  repo owner or an approved session. Do not work around the block.

- **"Byte-identical" lost to the identifier boundary — by a scrub table, not
  hand edits.** The export brief demanded both a byte-identical engine copy
  and "never copy real org/project IDs or keychain references". The engine
  files themselves carry a deploy project ref, app-store account IDs, the
  owner's email, the launchd label prefix, and a personally-named keychain
  service. The hard boundary wins: the sync applies a recorded substitution
  table (placeholders, never deletions), and a forbidden-pattern grep FAILS
  the sync if upstream introduces an identifier the table doesn't cover —
  that check caught the source repo's owner/name slug in a comment on its
  first live run. The export contract is "byte-identical modulo the scrub
  table" (`diff -r` against the pin prints exactly the substitutions).

- **The scrub table must not live in the repo it protects.** The
  fresh-context audit's top finding: an in-repo SCRUB_TABLE ships, verbatim,
  every identifier it exists to remove. The table (and the identifier-bearing
  forbidden patterns) moved to `scripts/scrub.local.tsv` — git-ignored,
  maintainer-machine-only — with `scripts/scrub.example.tsv` documenting the
  format. The sync refuses to run without the local file. Same lesson shape
  as the governance-copies note: the boundary applies to the *tooling* too.

- **No engine renames in v1 — not even good ones.** The governance analysis
  proposed renaming `factory/notify-vox.sh` to a neutral name. Declined: any
  engine edit breaks byte-identity with the pin and gets clobbered by
  `sync-from-source.sh` (which replaces `factory/` wholesale). Source-shaped
  names inside the engine are ADAPTERS.md entries, not renames. Renames
  happen upstream in the source repo first, then ride a re-sync.

- **`.factory/` here is scaffolding, so it is TRACKED.** First `.gitignore`
  draft ignored `.factory/evolution/` etc. — correct for a *bound* factory
  instance, wrong for this repo, which must ship those files empty. Runtime
  ignores live in `templates/gitignore.snippet` for the importing repo.

- **Engine layout mirrors the source repo on purpose.** `factory/` and
  `harness/` sit at the same top-level paths as in the source so that
  "import" is a plain byte-identical copy of two directories, and `diff -r`
  against any pin is a one-liner. Don't reorganize them into `engine/` — it
  would break the cheap-resync and the byte-identity check for zero benefit.

- **The first pin shipped the bug its own engine had just fixed upstream.**
  Pin 5f0363a was the exact commit that introduced the renumber-on-rebase
  path; the hot-fix (source e8f09a0) landed 52 minutes later and never rode a
  re-sync. In an importing repo the misfire was worse than at the source:
  `scripts/gen-migrations-index.mjs` is a documented dangling reference here,
  so every rebased PR would have escalated as a phantom "duplicate migration."
  CLOSED by the bd14e4f pin bump, which also brings
  `factory/tests/migration-race-selftest.sh` (verified passing against this
  repo's scrubbed copy). Lesson: the export is a snapshot — when the source
  hot-fixes the engine, bump the pin the same day, because a snapshot of a
  bug ships the bug.

- **Back up `scripts/scrub.local.tsv` — it is the public boundary's single
  point of failure.** The table is git-ignored and machine-local by design,
  which also means no clone of this repo can restore it. Losing it doesn't
  leak anything (the sync fails closed without it), but every rebuild-from-
  memory risks a missed identifier on the next sync. Procedure: keep one copy
  outside any git repo (password-manager secure note or an encrypted, non-
  synced folder — never a cloud-synced plaintext file, and never any path a
  repo could sweep up), and refresh that copy in the same sitting as any edit
  to the table. `scripts/scrub.example.tsv` documents the format only — real
  values live in exactly two places: the live file and its backup.
