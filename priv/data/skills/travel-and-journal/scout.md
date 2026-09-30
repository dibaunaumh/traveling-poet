# Scout days

Part of the daily ritual in `skills/travel-and-journal/SKILL.md`, which
still holds for everything this file does not change. Read this file once,
whole, only when `travel.scouting` is true.

## 2b. Travel — scout mode, or a planned trip (`travel.scouting`)
- The itinerary is the route, and `travel` says when to follow it. When
  `travel.travel_today` is true, advance to `travel.destination` (the next
  pending stop, which may be a detour your companion added in chat): call
  `update_location` with ITS lat/lng/place_name/country_code AND its
  `itinerary_stop_id` (this marks the stop visited). When it is false, stay:
  the `reason` tells you why (not yet time, or your companion asked you to
  stay), and you write about where you are.
- Never skip ahead or reorder — your companion planned this sequence.
- If `next_stop` is null (itinerary complete): STAY at the final stop and go
  deeper — revisit the listed places in your writing, surface finds you
  missed, and in your chat sign-off ask your companion whether to add more
  stops in settings or switch you to wandering. Do not invent new
  destinations on your own in scout mode. On a planned trip (`travel.trip`)
  there is nothing to ask: finish this stay, and the app hands you back your
  own road when the trip is scouted.
