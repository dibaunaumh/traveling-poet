defmodule TravelingPoetWeb.Api.BookApiController do
  @moduledoc """
  The poet's side of a composed book edition.

  `context` hands it the journey as the book will print it: chapters (stays)
  with a stable key, and per day the title, teaser, place or excursion, the
  poem, and the exact lines it may quote. `put_matter` takes what it wrote.

  Both work only while a paid composition is open (409 otherwise): the
  companion pays for a composition in Settings, and a request made in chat
  cannot write one for free.
  """

  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Accounts, Books, Poets, Topics}
  alias TravelingPoet.Books.{Manuscript, Matter, Quotes}
  alias TravelingPoetWeb.NotebookComponents

  # A long journey is paged by chapter so one reply never floods the turn.
  @days_inline_max 30

  def context(conn, params) do
    user = conn.assigns.agent_user

    with {:ok, poet} <- fetch_poet(user),
         {:ok, edition} <- fetch_open(poet) do
      manuscript = Books.manuscript(poet)
      quotables = Quotes.quotables(manuscript)
      total_days = manuscript.entry_count
      wanted = parse_chapter(params["chapter"])

      json(conn, %{
        edition_id: edition.id,
        poet: %{name: poet.name, personality: poet.personality, interests: poet.interests},
        companion: companion_name(user),
        journey: %{
          from: manuscript.from,
          to: manuscript.to,
          days: total_days,
          chapters: length(manuscript.chapters)
        },
        limits: Matter.limits(),
        written: written_summary(edition.matter),
        chapters:
          Enum.map(manuscript.chapters, fn ch ->
            include_days? =
              wanted == ch.number or (is_nil(wanted) and total_days <= @days_inline_max)

            chapter_payload(ch, include_days? && quotables)
          end),
        note:
          if(is_nil(wanted) and total_days > @days_inline_max,
            do:
              "This journey is long: days are not listed here. Call get_book_context with chapter: N for each chapter you write about.",
            else: nil
          )
      })
    else
      error -> render_error(conn, error)
    end
  end

  def put_matter(conn, params) do
    user = conn.assigns.agent_user

    with {:ok, poet} <- fetch_poet(user),
         {:ok, edition, report} <- Books.put_matter(poet, Map.drop(params, ["format"])) do
      json(conn, %{
        ok: true,
        edition_id: edition.id,
        written: report.written,
        rejected: report.rejected,
        accepted_quotes: report.accepted_quotes,
        dropped_quotes: report.dropped_quotes,
        unknown_chapters: report.unknown_chapters,
        missing_openers: report.missing_openers,
        complete: Matter.landed?(edition.matter) and report.missing_openers == []
      })
    else
      error -> render_error(conn, error)
    end
  end

  defp chapter_payload(chapter, quotables) do
    base = %{
      key: Manuscript.chapter_key(chapter),
      number: chapter.number,
      title: chapter.title,
      from: chapter.from,
      to: chapter.to,
      days: length(chapter.days),
      places: Enum.map(chapter.places, & &1.name)
    }

    if quotables,
      do: Map.put(base, :day_pages, Enum.map(chapter.days, &day_payload(&1, quotables))),
      else: base
  end

  defp day_payload(day, quotables) do
    entry = day.entry
    poem = Enum.find(entry.sections, &(&1.kind == "poem"))
    lines = Map.get(quotables, day.date, %{poem_lines: [], sentences: []})

    %{
      entry_date: day.date,
      journey_day: day.number,
      title: NotebookComponents.entry_title(entry),
      teaser: entry.teaser,
      place: entry.place_name,
      excursion: NotebookComponents.excursion_label(entry) || excursion_label(entry),
      poem_title: poem && poem.title,
      quotable_poem_lines: lines.poem_lines,
      quotable_sentences: lines.sentences
    }
  end

  defp excursion_label(entry), do: Topics.label_for_entry(entry)

  defp written_summary(matter) do
    matter = matter || %{}

    %{
      dedication: present?(matter["dedication"]),
      foreword: present?(matter["foreword"]),
      epilogue: present?(matter["epilogue"]),
      chapter_openers: matter |> Map.get("chapter_openers", %{}) |> Map.keys(),
      pull_quotes: length(Map.get(matter, "pull_quotes", []))
    }
  end

  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false

  defp parse_chapter(nil), do: nil

  defp parse_chapter(v) do
    case Integer.parse(to_string(v)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp companion_name(user) do
    case Accounts.get_user(user.id) do
      %{name: name} when is_binary(name) -> name |> String.split(" ") |> hd()
      _ -> nil
    end
  end

  defp fetch_poet(user) do
    case Poets.get_poet_by_user(user.id) do
      nil -> {:error, :no_poet}
      poet -> {:ok, poet}
    end
  end

  defp fetch_open(poet) do
    case Books.open_edition(poet) do
      nil -> {:error, :not_composing}
      edition -> {:ok, edition}
    end
  end

  defp render_error(conn, {:error, :no_poet}),
    do: conn |> put_status(404) |> json(%{error: "no poet configured"})

  defp render_error(conn, {:error, :not_composing}) do
    conn
    |> put_status(409)
    |> json(%{
      error: "no book composition is open",
      note:
        "A book edition is composed only when your companion asks for one in Settings, which starts /compose-book. If they asked in chat, tell them where to find it."
    })
  end
end
