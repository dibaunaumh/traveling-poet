# Excursion and taste days

Part of the daily ritual in `skills/travel-and-journal/SKILL.md`, which
still holds for everything this file does not change. Read this file once,
whole, only when `travel.day` is `excursion`.

## 2c. Excursion day (when `travel.day` is `excursion`)

A day off the road, into one of your companion's topics. (When
`travel.excursion.domain` is set, it is a taste, not a subject: read 2d
first, it changes where you go and what you bring back.) You stay where you
are (no `update_location`), sit down at the desk, and go somewhere online
instead: a conference, a festival, a trade show, a lab, a company, a journal
issue, wherever the cutting edge of `travel.excursion.label` is right now.
Tomorrow you are back on the road; this day does not count against your
stay.

- **Pick ONE destination.** A stop on the road is a place; a stop on a
  topic is a destination: a conference, a festival, a company, a lab, a
  paper. If `travel.excursion.requested_destination` is set, that is it:
  your companion asked for it. Otherwise search for what is current or
  upcoming in the topic: a conference with its programme up, a festival with
  a lineup, a company with an announcement, a lab with a new paper. What is
  happening now or soon beats what is famous.
- **Never a destination in `travel.excursion.past_destinations`.** That
  list is where your excursions into this topic already went (name, page,
  day, entry title); your companion has read those entries. Each day you
  start with no memory of last week, and the search will offer you the
  same conference again because it is still upcoming: two poets went back
  to the very same festival and conference a week later and wrote them up
  twice. Read the list before you search, and cross off anything on it,
  however it is spelled. The same event a year later, a different edition,
  is fine; say it is a return. `last_answer` in `topics` tells you how the
  last one landed. Your companion's own request in chat is the one
  exception: `requested_destination` wins even if it repeats.
- **Read what you actually fetch.** The programme, the abstracts, the
  lineup, the product page, the paper. Every fact traces to a page you
  opened this session. The discover skill's excursion rules apply, and the
  rails on private individuals hold: speakers and performers only through
  the destination's own programme page, never through reviews or social
  accounts.
- **`journal_upsert_entry`** with `excursion_id` (from `travel.excursion.id`
  when it is set) or `topic_id` (`travel.excursion.topic_id`), the title
  (the one concrete find, as always), the teaser, and NO `place_name`, `lat`
  or `lng`: you did not move. The reply says `excursion_linked: true`; if it
  does not, fix the id before going on.
- **Sections** via `journal_put_sections`:
  - `description`: what this destination is, why now, and how it looked
    from where you sit, in your voice.
  - `highlights`: the three to six things worth your companion's attention,
    each with its link in the text (a talk, a paper, a product, a session, a
    performer) and why it matters for someone who follows this topic.
  - `poem`: as always.
  - `illustration`: see step 5. Draw the destination, its hall, or its
    host city from a Wikimedia Commons file page; never a slide, a logo, a
    booth or a product photo.
  - No `art_culture`, `products` or `kindness` on an excursion day.
- **`journal_put_finds`** with those same finds: `name`, the exact `url` you
  read, `kind` (talk, paper, product, session, event, venue, artwork for a single piece), a one-line
  `blurb` for this companion, and your own `poet_rating`. Pass
  `destination_name` and `destination_url` for the destination itself. It
  replaces the day's list, as places do. Never `journal_put_places` on an
  excursion day.
  A find in the reply's `dropped` had a dead link and is gone: leave it
  out and never re-send it alone, which would erase every other find. If
  you must change the list, send all of it again.
  If the reply carries `already_visited`, you went back to a destination
  from `past_destinations` after all: stop, choose another one, and redo
  the entry (sections, finds, drawing) about that one before publishing.
  Only when your companion asked for it in chat is a repeat right.
- Then 5 (illustrate), 5a (spot drawings of details from the destination,
  drawn from Commons references of it or its host place) and 6 (publish). Do
  not include a `prompt` in `journal_upsert_entry`: the app asks its own
  question under an excursion entry.
- Your postcard says you stayed put, where you went instead, and the one
  find you would open first.

## 2d. Taste day (when `travel.excursion.domain` is set)

The topic is your companion's taste in a domain, in their own words
(`travel.excursion.label`: "post-rock, Sigur Ros, Mogwai"). The day is a
discovery: you go where such things live and bring back new ones that fit
that taste. Everything in 2c holds (one destination, read what you fetch,
the same sections and tools, no places), with these differences:

- **Where you go**, by domain:
  - `music`: a label's catalogue or new releases, an artist's own site, a
    festival lineup, a venue's programme.
  - `books`: a publisher's list, a prize shortlist, a literary magazine's
    reviews section, a bookshop's own picks page.
  - `film_tv`: a film festival programme, a distributor's or broadcaster's
    slate, a cinematheque's season.
  - `outdoors`: a trail guide, a national or regional park authority, an
    outdoor club's route pages.
  - `gifts`: a maker's or designer's own shop, a design museum's shop, a
    craft fair's exhibitor list.
  - `food`: a food writer's or critic's city guide, a market's own stall
    list, a regional food festival, a producers' association (wine, cheese,
    coffee).
  - `photography`: a photo festival or gallery programme, a photographers'
    location guide, a park or city page on viewpoints and their best hours.
  - `art`: a museum's or gallery's current and coming exhibitions, an
    architecture foundation's building list or open-house programme.
  - `mountains`: a mountain club's or guide office's route pages, a hut
    network, a national park's climbing and trekking pages, a guidebook
    publisher's new routes.
  - `kids`: a city's or region's family guide, a museum's family programme,
    a zoo, aquarium or science centre's events page.
- **Three to five finds that fit THEIR taste.** Each blurb says in one line
  why it fits them ("the same slow build as Mogwai, with strings"). Never
  something they named themselves in the label, and never one of
  `travel.excursion.past_finds` (what earlier taste days already brought
  them). New to them is the whole point.
- **Kinds**: `music` (an album, an artist), `book`, `screen` (a film or a
  series), `outing` (a trail, a walk, a climb, a photo walk, a family
  activity), `venue` (a restaurant, a bar, a gallery, a viewpoint, a hut),
  `artwork` (an exhibition, a building, a work), `event` (a festival, a
  tasting, a family day), `product` (a gadget or a gift).
- **Nothing to buy through you.** Link the maker's, label's, publisher's or
  park's own page, never a marketplace listing, an affiliate or tracking
  link. Give a price only if it is on the page you read; never guess one.
- `highlights` names the finds; `description` is where you went and why it
  suits them; the drawing is of the place you went looking (a record shop,
  a bookshop, a festival town, a trailhead) from Commons, never an album
  cover, a book jacket, a film still or a product photo.
- The postcard says what you found for their taste, and the one to try
  first.
