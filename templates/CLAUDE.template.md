<!-- TEMPLATE — CLAUDE.template.md
     CLAUDE.md is per-project by definition: it holds the conventions a coding
     agent follows with a human present. If your repo already has a CLAUDE.md,
     paste the "Factory governance" block below into it and do not maintain two
     files. If not, copy this to your repo root as CLAUDE.md and fill the
     convention sections. The factory's implement node reads this file, so
     every rule here is a rule the builder follows unsupervised. -->

# {{PROJECT_NAME}} — conventions

## Factory governance (dark-factory)

This repo carries the three-file governance split: **`MISSION.md`** (what
{{PROJECT_NAME}} is and is never; hard invariants), **`FACTORY_RULES.md`** (how an
unsupervised agent operates: protected files, prohibitions, escalation), and this file
(conventions only — how the code is written). Placement test for any new rule: would you
write it with a human working? → here. Only because nobody watches? → FACTORY_RULES.md.
About what the product is? → MISSION.md. Where a product truth appears both here and in
MISSION.md, the duplication is deliberate — the file read at reject time must contain the
rule. All three files are protected: no agent may edit the rules it is judged by; changes
are human commits. Work enters {{PROJECT_NAME}} as GitHub issues and the dark factory
builds it — see `FACTORY.md`.

## Stack

<!-- FILL: the locked stack, one line per layer. Mark it "do not re-litigate
     without new evidence" if that is your convention. -->
{{STACK}}

## Naming

<!-- FILL: DB, code, and file naming rules. -->
{{NAMING_RULES}}

## Structure

<!-- FILL: where code lives, the canonical data flow, where tests go. -->
{{STRUCTURE_RULES}}

## Patterns

<!-- FILL: the idioms the builder must follow and the anti-patterns it must not
     copy (typing strictness, import style, error handling, state management). -->
{{PATTERNS}}

## Commits

<!-- FILL: the commit convention — MUST agree with the {{COMMIT_CONVENTION}}
     slot in FACTORY_RULES.md §2 ("Every PR must"); the factory's commit step
     applies whichever is written here. -->
{{COMMIT_CONVENTION}}

## Database migrations

<!-- FILL: the one correct procedure — naming, numbering, header, apply
     mechanism, index regeneration. MUST agree with FACTORY_RULES.md §2.3–2.4
     (and §2.4a if the prod-apply road is enabled); harness/migration_lint.py
     enforces the file rules in code. -->
{{MIGRATION_PROCEDURE}}
