# Expected annotations — Moby-Dick Ch. 42, golden paragraph

**FLAGGED FOR HUMAN REVIEW.** Drafted by Claude; this file is the eval's definition of
quality and should not be trusted uncritically — Joseph should read it before it's used
to score anything.

## Golden paragraph

From `eval/fixtures/moby_dick_ch42.txt` (lines 92-95):

> Bethink thee of the albatross, whence come those clouds of spiritual wonderment and pale
> dread, in which that white phantom sails in all imaginations? Not Coleridge first threw
> that spell; but God's great, unflattering laureate, Nature.

## Expected annotations

| anchor | type | note |
|---|---|---|
| `the albatross` | context | In maritime superstition, sighting an albatross was an omen (fair or foul); killing one was thought to bring a curse on the ship — the folk belief Melville is invoking before naming Coleridge. |
| `Coleridge` | allusion | Samuel Taylor Coleridge, "The Rime of the Ancient Mariner" (1798): the Mariner shoots an albatross and is cursed, and the bird becomes an emblem of guilt hung round his neck. |
| `Not Coleridge first threw that spell; but God's great, unflattering laureate, Nature.` | interpretation | Melville argues the albatross's numinous dread precedes and exceeds Coleridge's poem — the source is Nature itself, not literature, framing whiteness as a pre-literary terror the whale will inherit. |
| `laureate` | philology | Literally an officially appointed poet (e.g. Poet Laureate); applied to "Nature" as a knowing paradox — an "unflattering" laureate is one that composes truthfully rather than to please a patron. |

## Notes for reviewer

- The spec draft that requested this file also named a "Heidelburgh Tun" callback as an
  expected element. That reference does not occur in Chapter 42 — the Great Heidelburgh
  Tun is Chapter 77 (the whale's head). I did not fabricate a callback to make the count
  match; flagging the discrepancy here instead.
- Other named examples from the spec (White Steed of the Prairies, tapa/White Squall,
  Whitsuntide) do appear later in this chapter but outside the golden paragraph chosen
  above — see lines 137-164, 176-177, and 218 of the fixture if a different/longer golden
  span is wanted instead of this one paragraph.
- Density here (4 annotations / 1 paragraph, ~2 sentences) is intentionally on the high
  end — this paragraph is the chapter's thesis statement and is unusually allusion-dense
  even for Ch. 42. Don't use this ratio as the target density for the whole chapter.
