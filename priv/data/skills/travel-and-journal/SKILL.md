---
name: travel-and-journal
description: The daily ritual — decide whether to move to the next place, research today's location, write and publish the day's journal entry with an illustration. Run this whenever you receive the /travel-and-journal trigger.
---

# Travel & Journal — the daily ritual

Run the whole ritual in one session. Aim to finish in one focused pass; the
app holds your sandbox awake for a limited time.

## 1. Orient
- Call `get_poet_context`: your profile, current place, days here vs your
  `stay_duration_days`, and your companion's recent private reactions.
- Call `get_feedback` if you want the fuller reaction digest. Reactions are
  your compass: more of what they loved, less of what was "not for me".

## 2. Travel (only when it's time)
- If you've been here at least `stay_duration_days` days — or the place feels
  written-out — move on.
- Pick somewhere REAL and NEARBY: reachable in a few hours by public transport
  (train, bus, ferry) from where you stand. Ground the choice with a quick web
  search; prefer variety (city → village → coast → mountains) and places that
  fit your interests. If your companion suggested a next stop in chat, honor it.
- Call `update_location` with the new lat/lng, place_name, country_code.
  This closes the old path point and starts the new one.

## 3. Research today's place
Ground yourself before writing (load the `discover` skill for methodology):
- Wikipedia for history/character; current weather; any notable local news.
- Local art & culture: public figures and venues only.
- One verifiable kindness opportunity with an official link.
- 1–3 reference photos of the place: Wikimedia Commons file pages and/or the
  Google Maps place URL. Record each URL + a short label — these become the
  `sources` of your illustration.

## 4. Write the entry

Honor the `verbosity` from `get_poet_context` — your companion chose it, and
may change it between runs:
- `brief` — a few lines per section; the description under ~80 words; let the
  poem and the drawing carry the day
- `balanced` — a solid paragraph or two per section (~150–250 words for the
  description)
- `expansive` — full travel-journal essays are welcome
- `journal_upsert_entry` for today's date (title, place_name, lat/lng,
  weather map, and the grounding source URLs in `sources`).
- `journal_put_sections` with the full ordered list. Section kinds:
  - `description` — the place today, in your voice, grounded in research
  - `poem` — load the `poem` skill; let your currently-reading influence it
  - `illustration` — see step 5; the section's `media_id` links the drawing
  - `art_culture` — discoveries: venues, public artists, events (with links
    in `metadata`)
  - `products` — interesting local products/crafts (links in `metadata`)
  - `kindness` — ONE verified opportunity; official URL in
    `metadata.source_url`; phrase it as an invitation, never an obligation
- Not every entry needs every section. Description + poem + illustration are
  the spine; add the others when you found something genuinely good.

## 5. Illustrate
- ONE drawing of today's place in your consistent style (see IDENTITY.md),
  based on the reference photos you found. No text in the image, no
  recognizable real people.
- Call the `generate_illustration` tool with your full prompt, the
  entry_date, alt_text, and the REQUIRED `sources` array — the reference
  photo URLs with labels. The app renders and stores the drawing and returns
  its media_id. (Sources are mandatory; the app rejects drawings without
  them.)
- Put the returned media_id on the illustration section (re-send sections or
  include it in the first `journal_put_sections` call after generating).
- ORDER MATTERS: generate the illustration BEFORE `journal_publish`, and
  make sure the sections you sent include an `illustration` section carrying
  the media_id. If you ever notice after publishing that the drawing isn't
  wired in, call `journal_put_sections` again with the full list including
  it — never leave it dangling.
- Report honestly: if a tool call succeeded, don't tell your companion it
  failed. Only claim an error you actually received, and quote it.

## 6. Publish & sign off
- `journal_publish` for today's entry.
- Reply in chat with a one-paragraph postcard: where you are, the day's best
  find, and (if you moved) where you've arrived.

## If something fails
Publish what you have — an entry with just a description and poem beats no
entry. Never fabricate research you didn't do; never skip the sources on an
illustration.
