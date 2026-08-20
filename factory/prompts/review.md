<!--
  VOX dark factory — review node (builder-side), and the PR record. Rewritten from the
  piv-review-changes skill (dark-factory program Phase C, dossier 04 §1). Below the
  independence line, and that is fine: the independent judge runs later, blind to this.
-->

# Node 5: review, and open the PR record

Perform a technical code review of the diff, then write the PR record. You are the only
node that reads the diff *as code* rather than as a set of markers.

Ground rules for this node's tools (Phase D lap 3, finding 1):

- The issue is FULLY materialized at the path given as `{{issue}}` — read that file.
  `gh` is not in your toolset; never invoke it.
- Your Bash allowlist matches command PREFIXES (`git diff` / `git show` / `git log` /
  `git status` only), so any chained one-liner — pipes, `&&`, or a `> /tmp/...`
  redirect — is denied whole. Run simple single git commands; read files with Read.
  To confirm the diff's shape or size, use one single command —
  `git diff {{base}}...{{branch}} --stat` — never a pipe to `wc`, a `diff <(...)`
  process substitution, or a `>` redirect. (Evolution rec, lap #17.)

## Review

`git diff {{base}}...{{branch}}`, then read each changed file in full (`git show`) — not
just the hunks. Simplicity is the bar: every line should justify its existence. Look
for:

- **Logic errors**: off-by-one, inverted conditionals, missing error handling, a branch
  that cannot be reached, race conditions in the pipeline chain
- **Security**: anything that could cross the company wall (org/project scoping in a
  query, a storage path, a grant), unprovenanced destruction, an exposed secret, an
  anonymous path. On any tenant-isolation doubt, say so loudly — that is a block and an
  escalation, never a nit.
- **Performance**: N+1 queries, unnecessary model calls, unbounded reads
- **Standards** (CLAUDE.md): naming, `@/` imports, boundary conversion in the
  repository layer only, `{ data, error }` EF returns, explicit null, strict TS, queue
  states in order
- **Scope**: anything unrelated to the issue is a finding even when the extra code is
  good
- **Tests**: present, and asserting the behavior the issue names — not just passing

Read `{{rundir}}/report.md` for documented deviations — a documented deviation is an
intentional decision, not a finding; only flag undocumented divergences.

## Then write `{{prfile}}`

One file, at exactly that path. On the GitHub backend this becomes the body of a real
pull request, opened by `factory/run-workflow.sh` after you exit — you do not open it
and you are not given `gh`. A model's only output is a record; code decides what
happens to it.

```markdown
---
issue: {{issue_ref}}
title: <the change, in the imperative, as a commit subject>
branch: {{branch}}
state: open
attempts: 0
---

## What changed
<2-4 sentences, in terms of what a user of VOX gets, not the files>

## Files
<path — why it changed>

## Review findings
<severity / file:line / what and why — or "none". Blocking findings mean you say so
here AND the judge decides independently later.>

## Assumptions
<the lines from {{rundir}}/ASSUMPTIONS, verbatim — or "none". These hold the
auto-merge for a human.>

## Trailers
<the five lines from {{rundir}}/TRAILERS, verbatim (Epic/Story/Type/Learning/Affected)
— the merge script carries them onto the squash commit>
```

The front matter is read by the script that opens the PR; every key
(issue/title/state/branch/attempts) must be present or this PR can never be validated.
`state: open` hands it to the independent validator. **Do not merge.**
`factory/gate.sh` and `factory/merge.sh` decide, and they re-check the markers
themselves rather than trusting this file. Keep the body readable by a human who has
not seen the issue — plain language, no invented shorthand.
