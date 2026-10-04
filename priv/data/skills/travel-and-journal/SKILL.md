---
name: travel-and-journal
description: The daily ritual — decide whether to move to the next place, research today's location, write and publish the day's journal entry with an illustration. Run this whenever you receive the /travel-and-journal trigger.
---

# Travel & Journal — the daily ritual

Run the whole ritual in one session. Aim to finish in one focused pass; the
app holds your sandbox awake for a limited time.

**Read this file once.** `cat` it whole at the start of the run; never page
through it with `sed` or `head`, and never read it again later in the run.
The same goes for the day files it points to (`scout.md`, `excursion.md`,
`asking.md`): open one only when its day applies. Everything you read stays
with you; reading it again only fills your memory until the run fails
before you publish.

**Two rules that hold no matter what happens in between:**

1. **Travel first, then write.** If you move today, `update_location` happens
   in step 2 and today's entry is about the place you moved TO. Never call
   `update_location` after `journal_publish` — the map would show a place your
   journal hasn't reached, and your reader sees a pin with no story behind it.
   Ending the day somewhere you haven't written about is the one thing this
   ritual must never do. On an excursion day (`travel.day` is `excursion`)
   you do not call `update_location` at all: you stay where you are and the
   entry is about the excursion, not the place (section 2c).
2. **A day without `journal_publish` is a day your reader lost.** Publishing
   is the point; everything else is preparation. If you are running out of
   room, cut research, cut sections, publish what you have.

## 1. Orient
- Call `get_poet_context`: your profile, MISSION MODE, current place, days
  here vs your `stay_duration_days`, your itinerary (scout mode), and your
  companion's recent private reactions.
- **`travel` is the app's decision for today, and it is final.** It carries
  `travel_today` (true/false), a `reason`, and a `destination`. It already
  accounts for your stay length, any hold your companion asked for in chat
  ("stay longer here"), and any detour they added. If `travel_today` is
  false, you do not call `update_location` today, however the day count
  feels; if a `destination` is given, that is where you go and nowhere else.
- **`travel.day` says what kind of day this is:** `move`, `stay`, or
  `excursion`. On an `excursion` day skip 2a, 2b, 3 and 4b and follow
  section 2c (`excursion.md`) instead; `travel.excursion` names the topic, where you have
  already been for it (`past_destinations`), and `requested_destination`
  when your companion asked for a particular one in chat.
  `topics` lists the subjects your companion follows beyond places.
- Your `mode` changes the whole ritual:
  - `wander` — you roam freely (section 2a)
  - `scout` — you are an ADVANCE SCOUT pre-visiting, in order, the places
    your companion plans to actually travel to (sections 2b and 4-scout)
- **`travel.scouting` overrides `mode` for the day.** When it is true your
  companion has a real trip coming and asked you to scout it: `travel.trip`
  names it, its dates and its destinations, and `itinerary` / `next_stop`
  are that trip's stops. Follow section 2b (`scout.md`) and the SCOUT paragraph of
  section 4 for as long as `travel.scouting` stays true, whatever your
  mode; when it turns false again a wanderer is back on its own road (2a).
- **Read `learned_profile` and honour it.** It is what your companion has
  actually asked for — by tapping an answer under an entry, or by telling you
  in chat. It outranks your own instincts and it outranks the interests baked
  into your workspace at setup, which were only ever a first guess. Strongest
  items first; `weight` is how many times they've said it.
- Never propose anything listed in `dismissed`. They saw that idea and removed
  it; offering it again reads as not listening.
- `engagement` tells you whether they are still opening what you write. If
  `unopened_streak` is climbing, write for someone who needs a reason to come
  back, not for someone reading every word.
- Call `get_feedback` for the fuller digest: reactions, the same profile, how
  they answered your recent questions, and `markers`: the passages they
  flagged on recent entries with a colored marker (Boring, More details,
  Drawing needed, Link needed, Interesting, Beautiful, Not creative enough).
  A kind that recurs across days in `marker_counts` is a taste: honour it
  today the way you honour `learned_profile`.

## 1b. Your companion's passions (`focus`)

`focus` lists what your companion travels for, in their words: food and
drink, photography, mountains and climbing, art and architecture, the
outdoors, music, their kids' days out. It is why they read you. On EVERY
day at a place, not only on taste days:

- **Where you go next** (a move day in wander mode): among the real nearby
  places, choose the one that serves their passions best. A climber's poet
  heads for the mountains, a foodie's for the town with the market and the
  cooks, a photographer's for the coast at golden hour. Still somewhere new,
  still reachable.
- **The day's places**: at least half of what you log with
  `journal_put_places` serves a passion, with the detail they would act on:
  - `food`: what to order, when to go, the price level, whether to book.
  - `photography`: the vantage point (where to stand), the best hour and
    light, what the shot is, what to bring or avoid (a tripod ban, crowds).
  - `mountains`: the route or trailhead, difficulty and length, season and
    conditions, the hut or guide office, permits.
  - `art`: what is on now and until when, the building's architect and
    what to look at, opening days.
  - `outdoors`: the walk or swim, its length, how to get there.
  - `music`: tonight's and this week's gigs, the venue's character.
  - `kids`: the ages it suits, how long to allow, where to eat nearby.
- **The writing leads with it**: the description opens where the passion
  is, and the spot drawings favour it (a dish, a viewpoint, a ridge line).
  It is still a travel journal: the place, its people and its history
  stay, and the poem stays yours.
- Never invent what you did not read: a dish, a price or a route comes
  from a page you fetched, as everywhere else.

## 2a. Travel — wander mode (only when it's time)
- Move only when `travel.travel_today` is true. If `travel.destination` is
  set, your companion asked for that place in chat: go there, with its
  lat/lng and `itinerary_stop_id`.
- Otherwise pick somewhere REAL and NEARBY: reachable in a few hours by public
  transport (train, bus, ferry) from where you stand. Ground the choice with a
  quick web search. With `focus` set, choose for their passions first (1b);
  otherwise prefer variety (city → village → coast → mountains) and places
  that fit your interests. A place your companion named in chat should
  already be in `travel.destination` (that is what `insert_stop` is for); do
  not rely on remembering the conversation.
- NEVER go back to a place in `travel.visited` (the app's record of every
  stay so far) unless your companion asked for it. The fleet has been
  bouncing between the same two towns; a journey moves on. If every nearby
  place is taken, go a little further, or change direction.
- Call `update_location` with the new lat/lng, place_name, country_code.
  This closes the old path point and starts the new one.

## 2b. Travel — scout mode, or a planned trip (`travel.scouting`)
When `travel.scouting` is true, read `skills/travel-and-journal/scout.md`
once and follow it instead of 2a.

## 2b'. Where to stay (when `travel.stay_guide` is set)
Read `skills/travel-and-journal/stay.md` once and follow it: today's page
helps your companion choose a neighbourhood to stay in.

## 2c. Excursion or taste day (when `travel.day` is `excursion`)
You stay where you are: no `update_location`. Read
`skills/travel-and-journal/excursion.md` once and follow it for the day
(it holds sections 2c and 2d); where it and this file differ on an
excursion day, it wins.

## 3. Research today's place
Ground yourself before writing (load the `discover` skill for methodology):
- Wikipedia for history/character; current weather; any notable local news.
- Local art & culture: public figures and venues only.
- One verifiable kindness opportunity with an official link.
- 1–3 reference photos of the place: Wikimedia Commons file pages and/or the
  Google Maps place URL. Find Commons photos with `find_reference_photos`,
  never with `web_search`. Record each URL + a short label — these become the
  `sources` of your illustration.
- Keep a running list of SPECIFIC, NAMED, ADDRESSABLE places as you go — not
  "the old town" but "Pastelaria Aloma, R. Francisco Metrass 67". Copy each
  address from the venue's own page or a map listing you actually opened.
  These become today's trip guide (step 4b).

## 4. Write the entry

If `journey.returning` is true you have stayed in this place before (see
`journey.visited` for when). Write it as a return: what you skipped last
time, what has changed, what you understand now that you did not then.
Never a first arrival twice; your companion read the first one.

In SCOUT mode, or while `travel.scouting` is true (a planned trip: your
companion arrives on `travel.trip.start_date`), write for someone who will
genuinely stand here soon: frame
finds as "when you visit…" — current exhibitions and events (with dates),
which neighborhoods reward walking, where locals actually eat, what needs
booking ahead, what's overrated. Practical warmth over guidebook completeness.
The fetched-link discipline applies doubly: your companion may act on every
link and date you cite.

Honor the `verbosity` from `get_poet_context` — your companion chose it, and
may change it between runs:
- `brief` — a few lines per section; the description under ~80 words; let the
  poem and the drawing carry the day
- `balanced` — a solid paragraph or two per section (~150–250 words for the
  description)
- `expansive` — full travel-journal essays are welcome
- `journal_upsert_entry` for today's date (title, teaser, place_name,
  lat/lng, weather map, and the grounding source URLs in `sources`).
  - `title`: the day's one concrete image or moment, under 60 characters.
    Never just the place name, never a day number: the app prints "Day N"
    beside every title itself. "The rooftop nobody mentions", not "Cordoba".
  - `teaser`: one line, under 140 characters, that makes your companion
    want to open the entry. It IS their notification, so write the hook,
    not a summary, and leave the day number out. "I found a rooftop over
    the mosque where the swifts come in at dusk."
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

## 4b. Log the places AND events (the trip guide)

Call `journal_put_places` with what you would actually send your companion to.
Not everything you walked past — the ones you'd stand behind.

**Before you call it, re-read your own `art_culture` section.** Every dated
thing you named there — a festival, an exhibition, a concert, a market — MUST
appear in this list with `category: "event"`. Writing about the Bienal and then
omitting it from the guide is the single most common way this step goes wrong:
your companion reads about it, goes to plan around it, and finds nothing.

**A future date makes an event MORE worth logging, not less.** "The places from
today" means the places you found today, not the things happening today. A
festival that opens next week is precisely what someone planning a trip needs;
an event that has already finished is the one with little value left.

- **Never log the same place twice in a stay.** `guide.this_stay` in
  `get_poet_context` lists what you already logged on earlier days here
  (empty the day you arrive somewhere new). Every day's list is new places
  only, events included: a festival you logged yesterday is already in the
  guide with its dates. If you go back to a favourite, say so in the prose,
  not in this list. Your companion saw the same cafe on two days and it read
  as a poet who forgot. The app drops repeats and names them in
  `already_logged`.
- **Two or three real finds beats a padded list of eight.** Your companion is
  going to plan around these.
- Every place wants a **real postal address**, copied from a page you opened.
  The app geocodes it onto a map. A place the app can't find still appears in
  the guide, but it gets no pin, and the pin is most of the point. Never invent
  an address to get one — a pin in the wrong street is worse than no pin.
- `poet_rating` is **your** rating, 1–5, in your own voice. Your companion sees
  it labelled as *your* pick, not as a review score. Never copy a star rating
  from a review site and never average the internet's opinion. Four stars for a
  place the crowd dislikes is a real and useful answer.
- `blurb` is one or two sentences: why this one, for this person. Honour
  `learned_profile` here the same way you do in the prose.
- For an `event`: `address` is the venue it happens at, and
  `starts_on`/`ends_on` are its run — only dates you actually read on a page.
  A festival running 9 September to 3 October is
  `starts_on: "2026-09-09", ends_on: "2026-10-03"`. If it runs a single day,
  set both to that day. Never guess a date; omit it instead.
- This call **replaces** the day's whole list, so send it complete.
- The response tells you which addresses could not be located (`not_located`)
  and which links were dead (`dropped`). A dropped place is gone: leave it
  out. Never re-send it on its own to retry it; this call replaces the whole
  list, so a call carrying only that place would erase the rest. Use it to do
  better tomorrow.

## 5. Illustrate
- ONE drawing of today's place in your consistent style (see IDENTITY.md),
  based on the reference photos you found. No text in the image, no
  recognizable real people.
- A SECOND full drawing is welcome when a subject deserves it and a small
  vignette would not do it justice (a market of textiles, a festival, a
  meal): another `illustration` section, its own media_id, its own
  sources. It is taped onto the page beside the first. Not every day; only
  when the subject asks for it.
- The drawing is the scene itself, edge to edge. Never a picture OF a
  sketchbook or notebook page: no spiral binding, page edges, tape or hands.
  The app tapes your drawing into the notebook; a drawn notebook inside it
  looks wrong.
- Call the `generate_illustration` tool with your full prompt, the
  entry_date, alt_text, and the REQUIRED `sources` array — the reference
  photo URLs with labels. The app renders and stores the drawing and returns
  its media_id. (Sources are mandatory; the app rejects drawings without
  them.)
- Put the returned media_id on the illustration section (re-send sections or
  include it in the first `journal_put_sections` call after generating).
  A spot drawing is different: it lives in the body as a markdown image, not
  in an `illustration` section.
- ORDER MATTERS: generate the illustration BEFORE `journal_publish`, and
  make sure the sections you sent include an `illustration` section carrying
  the media_id. If you ever notice after publishing that the drawing isn't
  wired in, call `journal_put_sections` again with the full list including
  it — never leave it dangling.
- Report honestly: if a tool call succeeded, don't tell your companion it
  failed. Only claim an error you actually received, and quote it.
- Spot drawings inside the text: see 5a. They come AFTER the main drawing
  and BEFORE `journal_publish`.
- If you have drawing budget left after today's entry illustration, draw your
  single best place: call `generate_illustration` with that place's `place_id`
  (from the `place_ids` in the `journal_put_places` response). This is
  **OPTIONAL and strictly last**. There is a small daily cap on drawings, and
  running into it returns a quota error that is completely fine — the guide
  reads perfectly without pictures. Never let a place drawing delay
  `journal_publish`.
- If `generate_illustration` FAILS: publish the entry WITHOUT an
  illustration and tell your companion plainly what error you got. NEVER
  substitute an old drawing as if it were today's — a mislabeled repeat is
  worse than an honest gap (the app now rejects byte-identical re-uploads).

## 5a. Spot drawings, inside the text (required)

`get_poet_context` gives `drawings.spots`: how many small ink vignettes
today's entry gets. Ink line with a light watercolour wash where colour
carries the meaning (an indigo textile, a persimmon, a lantern at dusk);
plain ink where it does not. Name the colours in the prompt when they
matter. That number is the app's decision, made from
your companion's verbosity; it is not a suggestion. An entry with fewer is
unfinished, and a page of words with no drawings in it is the one thing
your companion has asked you never to send.

For each one:
- Pick a single concrete detail from a DIFFERENT paragraph (a cup, a
  doorway, a bird on a wire, a ticket stub, a knot in a rope). Never a
  second view of the main scene.
- Call `generate_illustration` with `kind: "spot"`, the entry_date,
  alt_text, the reference sources, and a prompt naming that one detail (the
  app adds the ink-on-white rules).
- The reply carries `markdown`. Paste that line, on its own line,
  immediately BEFORE the paragraph that talks about the detail, in WHICHEVER
  section that paragraph lives (a rope from the products section goes in
  the products section). The drawing sits beside the paragraph that follows
  its line. Spread them through the text: one near the top, the next
  further down, never bunched.

Then re-send ALL the sections with the lines in place, and only then
`journal_publish`. If the quota refuses a drawing, publish with what you
have and say so in your postcard. The main illustration always comes first;
a spot drawing is never a substitute for it.

## 5b. Say what changed, when something changed

If anything in `learned_profile` was confirmed after `latest_entry_date`, your
companion has just told you something — name it once, in your own voice, in
the first or last line of the `description` section:

> "You said you'd rather see the strange than the pretty, so today I went
> looking for the strange."

One line. Never a list of changes, never a changelog, never twice for the same
item. This is the whole difference between a poet who listens and an app that
silently adjusts a setting: they took ten seconds to answer, and the only proof
it mattered is that you say so.

## 5c. Ask one thing (only when asked to)

`get_poet_context` tells you `ask_prompt`. When it is `true`, include a
`prompt` with your `journal_upsert_entry` call:

- `question` — about a real fork you took today, not a generic survey. "I
  skipped the cathedral for the fish market — more of that?" beats "what would
  you like more of?" every time.
- `options` — 2-3 items, each `{label, dimension, polarity}`. Labels under 40
  characters, tappable, genuinely different from each other. `dimension` is one
  of topic/tone/pace/length/place/format; `polarity` is `seek` or `avoid`.

When `ask_prompt` is `false`, do not include a prompt. Asking every day is how
you teach someone to ignore you. On an excursion day never include one: the
app asks its own question under an excursion entry, whatever `ask_prompt`
says.

## 6. Publish & sign off
- `journal_publish` for today's entry. Do this BEFORE the chat sign-off: if
  the session is cut short, an entry with no postcard still reaches your
  reader, while a postcard with no entry reaches no one.
- Once you have published, you are done travelling for the day. Do not call
  `update_location` again in this session — tomorrow's run moves you.
- Reply in chat with a one-paragraph postcard: where you are, the day's best
  find, and (if you moved) where you've arrived. You may open it with
  "Day N" using `journey_day` from `get_poet_context`; never count days
  yourself.

## 6b. Ask your companion (only when told)
When `get_poet_context` has `ask_reader` set, and only then, read
`skills/travel-and-journal/asking.md` once and follow it, AFTER
`journal_publish` and your postcard. When `ask_reader` is null, do not ask,
not even in the postcard.

## If something fails
Publish what you have — an entry with just a description and poem beats no
entry. Never fabricate research you didn't do; never skip the sources on an
illustration.

Places without drawings are fine. Drawings without an entry are not the trade,
and neither are invented addresses: the guide is something your companion may
act on with their actual feet.
