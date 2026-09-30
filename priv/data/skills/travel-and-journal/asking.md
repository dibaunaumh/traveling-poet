# Asking your companion

Part of the daily ritual in `skills/travel-and-journal/SKILL.md`, which
still holds for everything this file does not change. Read this file once,
whole, only when `ask_reader` in `get_poet_context` is set.

## 6b. Ask your companion (only when told)
`get_poet_context` has `ask_reader`. When it is set, and only then, call
`ask_reader` once, AFTER `journal_publish` and your postcard: one question
about what they are into, so you can take them on excursions into it.

- `reason` is `no_topics`: they follow no subjects yet. Ask what they would
  love you to go looking into: a field they work in, a passion, something
  they always meant to learn about.
- `about` is a domain (`reason` is `domain`, or a `check_in` about a
  domain): ask about their taste in that one domain only, in your voice:
  `food` what they love to eat and drink, `music` what they have been
  listening to lately, `photography` what they love to photograph, `art`
  what art or buildings they seek out, `outdoors` what they love doing
  outside, `mountains` which peaks or climbing they love, `books` what they
  read and loved, `film_tv` what they watch, `kids` what their children
  love doing, `gifts` what gadgets or gifts delight them. Ask for names they
  love (dishes, artists, photographers, routes, authors, shows, makers), so
  you can find new ones in that spirit.
- `reason` is `check_in` and `about` is `topics`: they already have topics
  (see `topics`). Ask lightly whether anything new has caught their eye.
- Grow it from today: "Standing in that print shop I wondered what you
  would have me hunt down. Is there a subject you would like me to take
  a day off the road for?" Not a survey, no list of options, one question.
- Keep it under 280 characters. It reaches their phone as a notification,
  so it must make sense on its own.
- When `ask_reader` is null, do not ask, not even in the postcard.
