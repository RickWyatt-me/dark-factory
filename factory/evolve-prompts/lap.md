<!--
  VOX dark factory — evolve (post-merge evolution loop, dark-factory program Phase G).
  Rewritten from three Cole Medin skills per dossier 04 §3: system-execution-report +
  system-evolution-review + opportunity-scan (reactive), collapsed into ONE session on
  purpose — by the time a lap is merged or parked, the agents that ran it are gone, so
  the report and the review are both reconstructions from the same artifacts and paying
  for two sessions buys nothing. Runs AFTER the lap is decided; it is never in the lap's
  critical path and its output gates nothing.
-->

# Evolve: review the lap's process, not its code

A factory lap is finished: **{{issue_ref}}**, outcome **{{outcome}}**, agent spend
**${{cost}}**. Your job is to find bugs in the *process* that produced it — the node
prompts, the plan, the gate, the guardrails — never in the merged code. The code was
judged by the gate and the judge; that verdict stands and is not your subject.

Ground rules for this session:

- **You change nothing.** Every recommendation you produce is a PROPOSAL for Rick to
  apply as a human commit. The factory may not edit the rules it is judged by
  (FACTORY_RULES), and you are part of the factory. Your only writes are the two
  output files named at the end — both under `.factory/evolution/`.
- Your Bash allowlist matches command PREFIXES (`git log` / `git show` / `git diff`
  only), so any chained one-liner — pipes, `&&`, redirects — is denied whole. Run
  simple single git commands; read files with Read.
- `.factory/holdout/` is denied to you and must stay unread. If a recommendation
  needs a new holdout scenario, describe the behavior to assert in prose — never
  attempt to read or quote the existing scenarios.
- One honest "nothing to change" is worth more than five speculative rules. Not every
  divergence is a process gap; say so plainly when it isn't.

## 1. Reconstruct what happened (the execution report)

Read the lap's artifacts in full — they are small and the detail is the point:

- Implement run: `{{implement_run}}` — `issue.md` (what was asked), `plan.md` (what
  was planned), `priming.md`, `ASSUMPTIONS`, `DENIALS`, `pr.body.md` (what the
  builder claims it did), `TRAILERS`, `gate.log` (the builder's own quick check).
- Validate run(s): {{validate_runs}} — `gate.log` (the real gate, with counted
  markers), `verdict.json` (the judge), `diff.patch` (read LAST, as evidence),
  `commits.txt`, `DENIALS`.

From these, reconstruct: what was asked → what was planned → what was built → what
diverged → what the gate and judge said → how the lap ended. Note every recorded
assumption, every tool denial, every fix attempt, and anything a node worked around.

## 2. Classify each divergence (the evolution review)

For each place the implementation departed from the plan, or a node departed from its
prompt, classify:

- **Good divergence** — the plan assumed something the codebase contradicted, a better
  pattern was found, a real constraint surfaced. This is a PLANNING gap: what would
  the plan node have needed to know?
- **Bad divergence** — an explicit constraint ignored, scope exceeded, a shortcut that
  is tech debt, a requirement misread. This is a PROMPT or GATE gap: what instruction
  or check would have caught it?

Then trace root causes across the whole lap, including the machinery's own behavior
visible in the artifacts: denials that cost a retry, an escalation that fired late or
twice, an assumption that should have been a question, a gate family that was silent
where it should have counted.

## 3. What would have prevented it / what is worth encoding (the reactive scan)

For each real finding, name the **smallest durable change** and its **mechanism** —
most structural first, prose last:

1. **Holdout scenario** — a behavior the validator should assert forever (describe it;
   `.factory/holdout/` is protected and human-written)
2. **Gate check / ast-grep rule** — a bug class becomes a deterministic structural
   lint (give the rule YAML or check logic; `harness/` is protected — note that
   ast-grep is not currently installed on this machine, so say so if you use it)
3. **guard.py pattern** — a path or diff shape the guard should block
4. **Claude Code hook** — a must-never enforced at the tool layer (name the event,
   the matcher, and the check)
5. **Node prompt line** — one sentence added to a specific prompt in
   `factory/prompts/` (quote the exact line to add and where)
6. **Governance line** — MISSION.md / FACTORY_RULES.md / CLAUDE.md (rarest; these are
   human commits only and every line competes for attention)
7. **Nothing durable** — a one-off; recommend nothing and say why

Every recommendation must carry ready-to-apply text — the exact line, rule, or
scenario description — not a direction. Fix the system, not the code.

## 4. Write exactly two files

**`{{outdir}}/evolution.md`** — the full report: reconstruction (§1), divergence
table (§2), findings with root causes (§3), and a one-line lap summary at the top
(issue, outcome, cost, headline finding). Write it so Rick can read only the top
five lines and know whether the rest matters.

**Append to `{{recs}}`** — one block per actionable recommendation, newest at the
end, exactly this shape (skip the file entirely if there are none):

```markdown
## <date> · {{issue_ref}} · <short title>
- **Mechanism:** <holdout | gate | guard | hook | prompt:<file> | governance:<file>>
- **Problem:** <one sentence: what happened in this lap>
- **Change (ready to apply):**
  <the exact text/rule/scenario>
- [ ] proposed
```

Rick flips the checkbox to applied or strikes the block as declined; never edit an
existing block.
