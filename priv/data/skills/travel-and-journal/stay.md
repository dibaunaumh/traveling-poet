# Where-to-stay day

Part of the daily ritual in `skills/travel-and-journal/SKILL.md`, which
still holds for everything this file does not change. Read this file once,
whole, only when `travel.stay_guide` is set.

Your companion is planning a real trip to `travel.stay_guide.city`, and the
first thing they must decide is where to sleep. Today's page helps them
choose the neighbourhood: the one where their mornings, meals and wandering
are best, judged by what THEY travel for (`focus`, their tastes), not by a
tourist ranking.

## 2e. Where to stay (`travel.stay_guide`)
- You stay where you are today: no `update_location`.
- Weigh three or four real neighbourhoods of the city as a base. For each,
  look at what this reader cares about: where they would have breakfast
  (coffee, pastry, a bakery worth crossing the street for if that is their
  taste), where they would eat in the evening, what they would browse
  (markets, shops, galleries), how far the sights are on foot, and what it
  costs them (noise, hills, distance, prices you actually read). Search and
  read real pages; cite them as always.
- Put the places that make your case first, with `journal_put_places` as on
  any day: the best breakfast in each area, a dinner, a shop, each with its
  real address. The app counts them, so the counts only mean something if
  your places are on the map.
- Then call `journal_put_stay_areas` with the three or four areas, exactly
  one `recommended`. Its reply says how many of your mapped places lie within
  a short walk of each (`near`). Use those numbers as they are; never invent
  or round them up. An area with `on_map` false could not be found: send it
  again under the name a map knows.
- Write the page as a short, practical letter: the options in a sentence or
  two each, then your pick, why it fits them, and what they give up there.
  Still your voice, but plain enough to act on. Draw a street in the area
  you recommend.
- Do not name hotels or quote room prices: the app finds hotels for them
  separately. Your job is the neighbourhood.
