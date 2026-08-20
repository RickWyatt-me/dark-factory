# E2E fixtures

## pipeline-audio.m4a

The committed audio the pipeline E2E uploads as "a recording arriving from the
field". 11 seconds, mono AAC @32 kbps (49 KB), generated 2026-08-15 with macOS
`say` + `afconvert`. The spoken script — the ground truth every downstream
assertion keys on:

> "Crew of six on site today. We poured forty yards of concrete on the duct bank
> this morning and finished the east trench. Conduit delivery arrived at ten A M.
> No safety incidents."

`harness/e2e.py` asserts the transcript carries "duct bank" and "concrete"
(EXPECT_TOKENS — full words chosen to be robust to STT variance), that extraction
yields an entry about the pour, and the query journey asks "What did we pour on the
duct bank?" against the chunks this recording produced.

If you regenerate it, keep the script's distinctive tokens or update EXPECT_TOKENS,
the query question, and the e2e assertions in the same human commit — this file is
part of the protected harness (`FACTORY_RULES.md` §5).

Regeneration recipe:

```bash
say -o /tmp/vox-fixture.aiff "<script>"
afconvert -f m4af -d aac -b 32000 -c 1 /tmp/vox-fixture.aiff harness/fixtures/pipeline-audio.m4a
```
