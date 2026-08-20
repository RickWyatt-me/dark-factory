<!--
  VOX dark factory — scan (proactive opportunity scan, dark-factory program Phase G).
  Rewritten from the opportunity-scan skill's PROACTIVE mode per dossier 04 §3. The
  reactive mode lives in evolve.md and runs per lap; this one runs on the maintenance
  cadence (FACTORY.md) over a WINDOW of laps, and asks a different question — not "what
  went wrong here" but "what keeps happening". The two are deliberately never mixed:
  one report answering both answers neither.
-->

# Scan: what keeps happening across laps, and what should it become

You are looking at **{{lap_count}} laps from the last {{window_days}} days** of the
VOX dark factory. Nothing is broken. The question is: what recurs — divergence
patterns, repeated assumptions, repeated denials, repeated escalation causes,
repeated human interventions — and which recurrences are worth encoding into the
factory's AI layer.

Ground rules — same standing as every factory session:

- **You change nothing.** Recommendations are proposals for Rick's human commits.
  Your only writes are the two output files at the end, both under
  `.factory/evolution/`.
- Bash is PREFIX-matched (`git log` / `git show` / `git diff` only); no chains, no
  pipes, no redirects. Read files with Read.
- `.factory/holdout/` is denied and stays unread.
- **Aggregate, don't ingest.** Per-lap detail belongs to evolve.md's reports; read
  those first where they exist, and dip into raw run artifacts only to verify a
  pattern, never to re-derive what a report already says.
- Rank by (how often × what encoding it would save). A pattern that happened once is
  not a pattern. Say plainly when a frequent pattern is NOT worth encoding.

## Inputs

- Per-lap evolution reports: `.factory/evolution/*/evolution.md` (the digested view)
- Raw runs in the window: {{run_list}}
- The escalation ledger: `.factory/needs-human.md` (what reached a human, and why)
- The recommendations ledger: `{{recs}}` — check which past recommendations are
  still unapplied; a recommendation proposed twice is itself a finding
- Costs: {{cost_summary}}

## What to look for

- The same assumption recorded lap after lap → the answer belongs in a node prompt
  or the issue template, not in every lap's ASSUMPTIONS file
- The same tool denial every lap → the allowlist or the prompt's ground rules are
  wrong, and every denial is a paid retry
- The same gate family catching the same class → promote it upstream (a guard
  pattern or a quick-check the builder runs before the gate)
- The same escalation cause parking laps → either fix the cause or stop treating it
  as exceptional
- Cost drift — a node whose spend grows lap over lap, or a lap shape that costs
  double the median
- Human toil — anything Rick did by hand more than twice in the window that a
  mechanism could carry (mechanism palette and its preference order: holdout > gate/
  ast-grep > guard > hook > prompt line > governance line — most structural first;
  note that ast-grep is not currently installed if you reach for it)

## Write exactly two files

**`{{outfile}}`** — the scan report: the window's shape (laps, outcomes, total
spend), each recurring pattern with its evidence (which laps, how often), and each
recommendation with ready-to-apply text. Top five lines = the headline patterns, so
Rick can stop there if nothing bites.

**Append to `{{recs}}`** — one block per actionable recommendation, same shape the
per-lap loop uses (newest at the end; skip if none):

```markdown
## <date> · scan:{{window_days}}d · <short title>
- **Mechanism:** <holdout | gate | guard | hook | prompt:<file> | governance:<file>>
- **Problem:** <the recurrence, with its count and the laps it appeared in>
- **Change (ready to apply):**
  <the exact text/rule/scenario>
- [ ] proposed
```
