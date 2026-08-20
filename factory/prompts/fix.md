<!--
  VOX dark factory — fix node. Rewritten from the piv-fix-review-findings skill
  (dark-factory program Phase C, dossier 04 §1). Maps to the needs-fix cycle under the
  two-attempt cap; triage of "fix now vs defer" is the validator's verdict, not yours.
-->

# fix-pr

Address the independent validator's findings:

- **the verdict** — `{{findings}}`
- **the raw validation output** — `{{gatelog}}`

Read the verdict first, in full. Read the log when a finding names a check, because the
log says what the check actually printed and the verdict says what the judge made of it.

## What you get, and what you do not

You get **the findings and the issue** (`{{issue}}`). You do not get the plan or the
implementation report, deliberately: a fix that re-reads the plan tends to re-argue the
plan rather than address the finding, and the finding is the only thing that failed.

## Fix the finding, not the symptom

Take the findings one at a time, highest severity first. For each: understand the
cause, fix it in the source, and extend a test so the finding cannot silently return.

**The prohibition that matters most here** (FACTORY_RULES.md §2 and §6): when a check
is red, the cheapest repair is always to make the check quieter. Deleting the
assertion, loosening a tolerance, special-casing the test input, catching and
swallowing — all of these turn the light off rather than fix the wiring, and all are an
auto-reject. The protected paths that would let you do it are denied to this node; if
fixing a finding genuinely requires changing a check, the finding is not a code bug —
say so and stop. That is a needs-human escalation and a perfectly good outcome.

A finding whose substance re-litigates a settled decision without new evidence
(FACTORY_RULES.md §7.5) should not have survived the judge; if one did, say so in your
output rather than implementing it.

## Attempt cap

You are attempt {{attempts}} of 2 (FACTORY_RULES.md §8). If you do not believe a
finding is fixable within scope, say so **now** rather than spending the last attempt
on a guess — an escalation with a clear reason is worth more than a second failed
cycle.

## Then

Run **exactly this command, verbatim** — it is the only test command on your allowlist:

```
{{quick}}
```

Do not substitute another way of running the tests; a denied command is a fix that
never got checked. Then hand back to the independent validator. A fix is never
self-certified: the node that made the change does not get to decide the change worked.
