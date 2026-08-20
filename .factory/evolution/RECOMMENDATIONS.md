# Evolution recommendations — the reading list

Proposals from the post-lap evolution loop (`factory/evolve.sh`, FACTORY_RULES §9a).
Every block is ready-to-apply text; **applying one is always a human commit** — the
factory may not edit the rules it is judged by. The single exception is the §9b
prompt-only channel, disabled by default (`FACTORY_EVOLVE_APPLY_ENABLED=0`).

Block format (one per finding, newest first):

```
## YYYY-MM-DD · gh:issue:N · one-line finding
- **Mechanism:** prompt:factory/prompts/<file>.md   (or gate/guard/runner/governance)
- **Problem:** what actually happened in the lap, from run artifacts.
- **Change (ready to apply):** the exact edit, quoted.
- [ ] proposed          ← flips to `- [x] applied <date> (<who>)` or a strike-through
```
