# A local's tips

Part of the daily ritual in `skills/travel-and-journal/SKILL.md`, which
still holds for everything this file does not change. Read this file once,
whole, only when `local_voices` in `get_poet_context` lists a tip.

## 4a. A local's tips (only when `local_voices` has one)
`local_voices` in `get_poet_context` holds tips from readers who live where
you are: the app asked them for you. When it lists one, you may add ONE
`local_tip` section to today's entry:
- `metadata: {local_question_id: <its id>}`; the app adds who it is from
  under it. Never write their name or anything about them, in this section
  or any other; in your own prose they are "a reader who lives here".
- Their tips in your companion's language: translate them, keep their
  meaning and their voice, add nothing they did not say. A short title of
  your own is fine.
- Their word is a person's, not a page you fetched: check each place they
  name before it goes in `journal_put_places`, and leave out what you cannot
  find.
- If you have already left their city, say the note reached you after you
  left. Each tip goes on one page only.
