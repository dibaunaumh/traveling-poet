---
name: revise-entry
description: Revise a published entry from the feedback markers your companion left on it, and learn from them. Run this whenever you receive the /revise-entry trigger.
---

# Revise — your companion marked the page

Your companion read an entry with a set of colored markers in hand and left
some on it: a highlighted phrase, a whole section, a drawing. The trigger you
just received lists every marker with what it asks of you. This is the most
precise feedback you will ever get. Treat it as such.

## The one rule: change only what was marked

A revision is surgery, not a second draft. Only a marker that asks for a
change may change text, and only the passage it sits on. Every other section
goes back exactly as `journal_get_entry` returned it: same title, same
teaser, same body (including any `![...](/media/N)` spot drawing line in
it), same `media_id`, same `metadata`, word for word. Unmarked passages are the
ones your companion read and was content with; rewriting them, even into
better prose, throws away what they liked and is a failed revision.

Praise (Interesting, Beautiful, an Other note that only says thank you)
changes nothing today. It tells you what to do more of tomorrow.

The app enforces this: when it re-saves a marked entry it keeps every
unmarked section as it was, and its reply lists them under
`kept_as_written`. Never tell your companion you changed something that is
on that list.

## 1. Read before you write

- The trigger names the entry date and says whether it is your **latest**
  published entry.
- Call `journal_get_entry` for that date. It returns your sections exactly as
  they stand and the same markers with their `meaning` and `ask`. Never
  rewrite from memory: `journal_put_sections` replaces the whole list, and a
  section you forgot is a section your companion loses.

## 2. If it is not your latest entry

Do not touch the text. Older entries stay as they were written; the markers
on them are a lesson, not a work order. Go straight to step 5.

## 3. What each marker asks

| Marker | On prose | On an illustration |
|---|---|---|
| **Interesting** | Keep it exactly as it is. Do more of this kind of thing in the days ahead, not in this revision. | Keep it. |
| **Beautiful** | Keep it exactly as it is. It asks nothing of the rest of the entry. | Keep it. |
| **Boring** | Cut it, or sharpen it into one concrete, grounded image. | Replace it with a drawing of something else from the day, or drop it. |
| **More details** | Load `discover`, research the thing itself, and expand with cited facts. Never invent to fill the gap. | Draw a closer or fuller view, with new reference sources. |
| **Drawing needed** | Call `generate_illustration` with real reference sources and add an `illustration` section right beside the passage. | Redraw it from a different reference. |
| **Link needed** | Find the venue's or organization's real page (official site, Wikipedia, the museum's own hours page) and put it in the section's `metadata.source_url` with a `source_label`. Only a page you actually fetched. | Add the reference photo's page to the drawing's sources. |
| **Not creative enough** | Rewrite it in your own voice from a fresh angle, same facts. Change the way in, not the truth. | Redraw it from a different angle or moment, same place. |
| **Other feedback** | The trigger quotes your companion's own note about this passage. Read it and do what it asks, in voice, within that passage. If the note is praise, change nothing. If it reads as a standing wish rather than a note about this line, it may be worth a preference, with their words as the label. | Same: read the note and act on it. |

A marker on a whole section applies to all of it. A marker on a phrase applies
to that phrase and the sentence around it, not the whole section.

## 4. Re-put the entry and re-publish

- Send `journal_put_sections` with **every** section, changed or not, in
  order, keeping each `media_id` and `metadata` you are not changing.
- Then `journal_publish` for the same date. Publishing again is a revision:
  the reader is told the entry changed, nobody gets a second notification.
- Reply in chat with one or two sentences, in voice, naming what you changed.
  Never a changelog. If every marker was praise and nothing changed, one
  sentence of thanks is the whole reply. If a marker could not be honored (no
  real page exists, the drawing failed, the quota is spent), say so plainly
  instead of pretending.

## 5. Learn, but only when the pattern is clear

Markers are the start of a taste, not proof of one. Record a preference with
`record_preference` (with `source: "marker"` and the marked quotes as the
`quote`) only when:

- two or more markers in this trigger say the same thing (two Boring on
  history paragraphs; Drawing needed twice), or
- `get_feedback` shows `marker_counts` with the same kind three or more times
  across recent days.

At most **one** `record_preference` per revision. Never from a single marker.
Never turn "this paragraph" into a standing rule. Over-recording is worse than
missing one: a preference invented from one tap will quietly steer everything
you write for a month.

Read `learned_profile` before recording so you strengthen an existing
preference rather than adding a near-duplicate.

## Rails

- AGENTS.md holds throughout: real places, real sources, no invented facts,
  no private individuals, no spending.
- The entry stays about the same day and place. Do not call `update_location`.
- Never fabricate research to satisfy a More details marker. If you cannot
  find it, say so in your reply and leave the passage honest.
