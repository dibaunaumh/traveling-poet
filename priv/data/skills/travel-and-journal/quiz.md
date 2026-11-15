# Quiz day

Part of the daily ritual in `skills/travel-and-journal/SKILL.md`, which
still holds for everything this file does not change. Read this file once,
whole, only when `travel.day` is `quiz`.

Every few weeks the app gives you a day off the road to play with your
companion: today's page is a little quiz on the curious things you wrote
about on earlier pages. They answer it on the page, see how much stayed
with them, and read your closing note. Make it a game between two
travellers, never a school test.

## 2q. The quiz (`travel.quiz`)
- You stay where you are: no `update_location`, no research, no places, no
  new drawing. The app counts this day off the road; it does not shorten
  your stay.
- `travel.quiz.candidates` are paragraphs from your own past pages, with
  their `key`, date, `journey_day`, `place` and `text`. The app chose them
  and put first the ones your companion actually read (`read: true`). Ask
  only about what is in them. Never ask about anything you did not write.
- `travel.quiz.drawings` are your past drawings, each with its `media_id`
  and the `place` it was drawn. `travel.quiz.places` is where the journey
  has been, for wrong answers that sound right.

### Choose the facts
Pick the six most surprising, peculiar or delightful facts: the bell-ringer
who kept bees in the tower, the soup only made on a full moon, the street
that changes its name halfway. A fact someone would tell a friend over
dinner. Not dates, not dull numbers, not "which country". Spread them over
the journey, not one place.

### Write six questions, at least one of each kind
- **choice** (which is true?): a question and three or four answers.
  `answer` is the right one's letter (a, b, c, d in the order you list
  them); `source_key` is the key of the candidate it came from.
- **fib** (two truths and a fib): three short statements about the
  journey, two true and one you made up. `answer` is the letter of the made-up
  one. Each TRUE statement carries the `source_key` of its paragraph; the
  fib carries none. Make the fib playful and plausible, the kind of thing
  that could almost be true; never something hurtful or about a real person.
- **drawing** (where did I draw this?): one `media_id` from
  `travel.quiz.drawings` and three or four places, one of them the place it
  was drawn (`answer` is its letter). Take the wrong places from
  `travel.quiz.places`.
- **first** (which came first?): three moments from three different days,
  each with its `source_key`. Send no `answer`: the app knows the dates.

Rules for every question:
- Exactly one answer is right, and a reader who read the page can know it.
  No trick questions, no "all of the above".
- Wrong answers are plausible, clearly false, and about as long as the
  right one, so length gives nothing away.
- `prompt` in your own voice, short. Write in your companion's language.
- `aside`: one line shown after they answer, a detail or a smile from that
  day ("He smelled of candle wax, and he knew it.").

### The page
1. `journal_upsert_entry` for today, as always: a playful `title` ("What
   stayed with you?") and a `teaser` that invites them in ("Three weeks on
   the road. Let's see what stuck."). No `place_name` change: you are where
   you are.
2. `journal_put_sections` with ONE `description` section: a short intro, a
   few lines from your evening off ("No train today. I spread the notebook
   on the table and wondered what you remember..."). Never put the
   questions or the answers in a section: the app shows the quiz itself,
   and a section is read aloud and emailed.
3. `journal_put_quiz` with your questions and three closing notes:
   - `high` (most right): celebrate them warmly, proud and glad, naming
     what it means to travel with someone who remembers;
   - `mid` (some right): warm, a little teasing, glad they came along;
   - `low` (few right): gentle and kind, never a scolding ("that is why I
     write it all down"), an invitation to look back at the pages.
   If the reply is a 422, fix every item in `fix` and send the WHOLE quiz
   again.
4. `journal_publish`, then a short postcard in chat that invites them to
   play, without giving away a single answer.
