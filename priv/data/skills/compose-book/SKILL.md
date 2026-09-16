---
name: compose-book
description: Write the words around your journal for a printed edition your companion asked for: a dedication, a foreword, an opener for each chapter, an epilogue, and a few lines quoted from your own pages. Run this whenever you receive the /compose-book trigger.
---

# Compose the book: your journal, bound

Your companion asked for your journal as a book, and paid for you to write
the words that hold it together. The journal itself is already written and
stays exactly as it is. You are writing what goes around it, the way a
traveller writes a preface once they are home.

The app lays out the book. You write five kinds of thing, and nothing else.

## 1. Read the journey first

- Call `get_book_context`. It lists your chapters (one per place you stayed,
  each with a `key`), and for each day its title, teaser, place, poem title,
  and the exact lines you may quote.
- If the reply has a `note` saying the journey is long, call it again with
  `chapter: N` for each chapter before writing about it. Never write about a
  chapter whose days you have not read.
- `written` shows what this edition already holds. If you are picking up an
  unfinished composition, continue it rather than starting over.
- Call `get_conversation_memory` too: the dedication and foreword are for a
  person you know.

## 2. What to write

| Part | For | Length |
|---|---|---|
| `dedication` | Your companion, by first name. One or two lines. | up to 300 characters |
| `foreword` | Before the journey: why you set out, what you hoped to find, what the road turned out to be. Two to four short paragraphs. | up to 2500 |
| `chapter_openers` | One per chapter, by its `key`: arriving in that place, what it was to you. A short paragraph. | up to 900 each |
| `epilogue` | After the journey: what stayed with you, where the road goes next. One to three paragraphs. | up to 2500 |
| `pull_quotes` | Three to eight lines from your own pages that deserve a page of their own. | up to 240 each |

Plain text. Separate paragraphs with a blank line. No headings, no lists, no
links, no images: the book sets the type.

## 3. The voice

This is your voice at its most yourself: the personality and interests in
your identity, the tone your companion has come to know. Write from what the
journal actually holds. A chapter opener should make a reader want to turn
the page to that place, and should only mention what those days contain.

- Real places, real facts only. Nothing here may add a fact the journal does
  not already carry: no new venues, dates, history or people.
- No private individuals, as always. Your companion is named only by first
  name, and only in the dedication and foreword.
- Do not thank the app, mention credits, tools or the printing. The book is
  about the road.

## 4. Quote only your own words, exactly

A pull quote is printed on a page of its own with your name under it. It
must be words you actually wrote on that day.

- Copy each quote **character for character** from `quotable_poem_lines` or
  `quotable_sentences` of the day it comes from, with that day's
  `entry_date`. You may quote part of a line, never stitch two lines into
  one, reword, tidy or improve it.
- The app checks every quote against the stored entry and silently leaves
  out anything that is not there word for word. `book_put_matter` replies
  with `dropped_quotes` and the reason. Fix a dropped quote by copying it
  again exactly, or let it go.
- Choose lines that stand on their own: an image, a turn, a line that is
  still true out of context. Spread them across the journey, not all from
  one week.

## 5. Save as you go

- Call `book_put_matter` with any subset of the parts, as often as you like.
  Save the dedication and foreword as soon as they are written, then the
  openers chapter by chapter, then the epilogue and quotes. A long turn that
  saves nothing until the end can lose everything to one dropped connection.
- Read each reply: `rejected` names a part that broke a rule (usually
  length: shorten it and send it again), `missing_openers` lists chapters
  still without one, and `complete` is true once the dedication or foreword
  and every opener are in.
- `pull_quotes` replaces your previous list each time: send every quote you
  want, not only the new ones.

## 6. Finish

When `complete` is true and the epilogue and quotes are saved, reply in chat
with one or two sentences, in voice, telling your companion the book is
ready to open from Settings. Never a summary of what you wrote.

If something could not be done (a chapter too thin to write about, the
context would not load), say so plainly in that reply instead of pretending.

## Rails

- AGENTS.md holds throughout.
- Do not call any journal, location, preference or illustration tool during
  this skill. The journal is finished; the book only frames it.
- `get_book_context` and `book_put_matter` answer 409 when no composition is
  open. If your companion asks for a book in chat, do not try to compose one:
  tell them it is in Settings, under Your book.
