defmodule TravelingPoetWeb.BookComponents do
  @moduledoc """
  The pages of the printed journal.

  Built from a `Books.Manuscript`. The prose is rendered by the same
  `NotebookComponents.section/1` and `raw_markdown/3` as the screen pages,
  so the sanitizer and the media whitelist hold here too; everything around
  it (cover, contents, chapter openings, poem pages, sources, gazetteer,
  index, colophon) is the book's own. Page breaks and running heads are CSS
  (assets/css/book.css); nothing here knows about pages.

  Two rules the reader on paper depends on: every structured link prints
  its url next to its label, and a poet's rating always says whose it is.
  """

  use TravelingPoetWeb, :html

  import TravelingPoetWeb.NotebookComponents,
    only: [section: 1, raw_markdown: 3, entry_title: 1, excursion_label: 1]

  alias TravelingPoet.Books.Manuscript
  alias TravelingPoet.Guide.Place
  alias TravelingPoet.Journal.Media
  alias TravelingPoet.Topics
  alias TravelingPoetWeb.{GuideComponents, NotebookComponents}

  @route_max 8

  attr :manuscript, :map, required: true

  def cover(assigns) do
    ~H"""
    <section class="book-cover" id="book-cover">
      <div class="book-wordmark">Traveling <em>Poet</em></div>
      <img
        :if={@manuscript.poet.avatar_url}
        src={@manuscript.poet.avatar_url}
        alt=""
        class="book-avatar"
      />
      <h1>{@manuscript.title}</h1>
      <p class="book-subtitle">{@manuscript.subtitle}</p>
      <p :if={@manuscript.chapters != []} class="book-route">{route_line(@manuscript)}</p>
      <p class="book-route">
        {days_label(@manuscript.entry_count)}
        <span :if={@manuscript.colophon.chapter_count > 1}>
          in {@manuscript.colophon.chapter_count} places
        </span>
      </p>
    </section>
    """
  end

  defp route_line(%{chapters: chapters}) do
    names = Enum.map(chapters, &short_place(&1.title))

    case Enum.split(names, @route_max) do
      {shown, []} -> Enum.join(shown, " · ")
      {shown, rest} -> Enum.join(shown, " · ") <> " · and #{length(rest)} more"
    end
  end

  # "Lisbon, Portugal" reads as "Lisbon" on a cover line of eight.
  defp short_place(name) when is_binary(name),
    do: name |> String.split(",") |> hd() |> String.trim()

  defp short_place(other), do: other

  defp days_label(1), do: "One day"
  defp days_label(n), do: "#{n} days"

  attr :text, :string, required: true

  @doc "The dedication, alone on the page after the cover."
  def dedication(assigns) do
    ~H"""
    <section class="book-dedication" id="book-dedication">
      <div class="book-dedication-text">{raw_markdown(@text, [], [])}</div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :kicker, :string, required: true
  attr :title, :string, required: true
  attr :text, :string, required: true
  attr :signature, :string, required: true

  @doc "A page of the poet's own words around the journal: the foreword, the epilogue."
  def prose_page(assigns) do
    ~H"""
    <section class="book-prose-page" id={@id}>
      <p class="book-kicker">{@kicker}</p>
      <h2 class="book-h">{@title}</h2>
      <div class="book-matter prose">{raw_markdown(@text, [], [])}</div>
      <p class="book-signature">{@signature}</p>
    </section>
    """
  end

  attr :text, :string, required: true
  attr :day, :map, required: true
  attr :poet, :map, required: true

  @doc "A line the poet chose from its own page, set on a page of its own."
  def pull_quote(assigns) do
    ~H"""
    <section class="book-pull-quote">
      <blockquote>{@text}</blockquote>
      <p class="book-pull-quote-foot">
        {@poet.name}, day {@day.number}<span :if={@day.entry.place_name}>, {@day.entry.place_name}</span>
      </p>
    </section>
    """
  end

  @doc "The chapter's opener from a composed edition, if the poet wrote one."
  def opener(nil, _chapter), do: nil
  def opener(matter, chapter), do: Map.get(matter.openers, Manuscript.chapter_key(chapter))

  @doc "The verified pull quotes that follow a day."
  def quotes_for(nil, _day), do: []
  def quotes_for(matter, day), do: Map.get(matter.quotes_by_date, day.date, [])

  attr :manuscript, :map, required: true
  attr :matter, :map, default: nil

  def toc(assigns) do
    ~H"""
    <section class="book-toc" id="book-toc">
      <p class="book-kicker">Contents</p>
      <h2 class="book-h">The journey</h2>
      <p :if={@manuscript.chapters == []} class="book-muted">
        No pages yet. The first one lands the morning after the poet sets out.
      </p>
      <ol>
        <li :if={@matter && @matter.foreword} class="toc-chapter">
          <a href="#book-foreword"><span class="toc-title">Foreword</span></a>
        </li>
        <li :for={ch <- @manuscript.chapters} class="toc-chapter">
          <a href={"##{ch.anchor}"}>
            <span class="toc-title">{ch.number}. {ch.title}</span>
          </a>
          <ol class="toc-days">
            <li :for={d <- ch.days}>
              <a href={"##{d.anchor}"}>
                <span class="toc-day">Day {d.number}</span>
                <span class="toc-title">{entry_title(d.entry)}</span>
              </a>
            </li>
          </ol>
        </li>
        <li :if={@matter && @matter.epilogue} class="toc-chapter">
          <a href="#book-epilogue"><span class="toc-title">Epilogue</span></a>
        </li>
        <li :if={@manuscript.chapters != []} class="toc-chapter">
          <a href="#book-index"><span class="toc-title">Index</span></a>
        </li>
      </ol>
    </section>
    """
  end

  attr :chapter, :map, required: true
  attr :opener, :string, default: nil

  def chapter_opening(assigns) do
    ~H"""
    <section class="book-chapter" id={@chapter.anchor}>
      <p class="book-kicker">Chapter {@chapter.number}</p>
      <h2 class="book-chapter-title">{@chapter.title}</h2>
      <p class="book-chapter-dates">
        {date_range(@chapter.from, @chapter.to)} · {days_label(length(@chapter.days))}
      </p>
      <div :if={@opener} class="book-opener book-matter">{raw_markdown(@opener, [], [])}</div>
    </section>
    """
  end

  attr :day, :map, required: true
  attr :poet, :map, required: true

  @doc """
  One day: its page of prose with the drawings taped in, then, when the poet
  wrote one, the poem alone on a page of its own.
  """
  def day(assigns) do
    bundle = assigns.day.bundle
    entry = assigns.day.entry

    drawings =
      entry.sections
      |> Enum.filter(&(&1.kind == "illustration"))
      |> Enum.flat_map(&List.wrap(Map.get(bundle.media, &1.media_id)))
      |> Kernel.++(bundle.extra_media)
      |> Enum.uniq_by(& &1.id)

    assigns =
      assign(assigns,
        entry: entry,
        excursion: Topics.excursion_of(entry),
        drawings: drawings,
        prose: Enum.reject(entry.sections, &(&1.kind in ~w(illustration poem))),
        poems: Enum.filter(entry.sections, &(&1.kind == "poem")),
        spot_media: bundle.spot_media
      )

    ~H"""
    <article class="book-day" id={@day.anchor}>
      <header class="book-day-head">
        <span class="notebook-day">Day {@day.number}</span>
        <span class="notebook-date">{Calendar.strftime(@day.date, "%A, %B %-d, %Y")}</span>
        <h2 class="notebook-title">{entry_title(@entry)}</h2>
      </header>

      <div :if={@excursion} class="book-ticket">
        <div class="ticket-kicker">A day off the road</div>
        <div class="ticket-topic">An excursion into {excursion_label(@entry)}</div>
        <div :if={@excursion.venue_name}>{@excursion.venue_name}</div>
      </div>

      <.drawing :for={m <- @drawings} media={m} />

      <.section :for={s <- @prose} section={s} spot_media={@spot_media} />

      <.sources list={@day.sources} />

      <p class="book-day-foot">
        Read online: <a class="book-url" href={@day.url}>{@day.url}</a>
      </p>
    </article>

    <section :for={poem <- @poems} class="book-poem">
      <h3 class="notebook-section-title">{poem.title || "A poem"}</h3>
      <div class="book-poem-body prose">{raw_markdown(poem.body, @spot_media, [])}</div>
      <p class="book-poem-foot">
        {@poet.name}, day {@day.number}<span :if={@entry.place_name}>, {@entry.place_name}</span>
      </p>
    </section>
    """
  end

  attr :media, :map, required: true

  # The url of what it was drawn from is in the day's sources list; the
  # caption only names it, as the journal's does.
  defp drawing(assigns) do
    ~H"""
    <figure class="taped-photo">
      <img src={~p"/media/#{@media.id}"} alt={@media.alt_text || "drawing"} />
      <figcaption>
        <span :if={@media.alt_text}>{@media.alt_text}</span>
        <span :for={src <- Media.source_items(@media)} class="src">
          Drawn from {src["label"] || "the real place"}
        </span>
      </figcaption>
    </figure>
    """
  end

  attr :list, :list, required: true

  @doc "The day's citations, numbered, label and url both, so a printed page still leads somewhere."
  def sources(assigns) do
    ~H"""
    <div :if={@list != []} class="book-sources">
      <h3>Sources</h3>
      <ol>
        <li :for={s <- @list}>
          <span :if={s.label != s.url}>{s.label}</span>
          <a class="book-url" href={s.url}>{s.url}</a>
        </li>
      </ol>
    </div>
    """
  end

  attr :chapter, :map, required: true
  attr :poet, :map, required: true

  @doc "The chapter's places (or an excursion's finds), as the guide lists them, with addresses and urls."
  def gazetteer(assigns) do
    ~H"""
    <section :if={@chapter.places != []} class="book-gazetteer">
      <p class="book-kicker">Chapter {@chapter.number}</p>
      <h2 class="book-h">Places in {@chapter.title}</h2>
      <div
        :for={{place, i} <- Enum.with_index(@chapter.places, 1)}
        class="book-stop"
        style={"--stamp-c: #{NotebookComponents.stamp_color(Place.group_for(place.category))}"}
      >
        <div class="stop-n">{i}</div>
        <div>
          <span class="stop-name">{place.name}</span>
          <span class="stop-cat">{GuideComponents.humanize_category(place.category)}</span>
          <div :if={place.address} class="stop-address">{place.address}</div>
          <div :if={event_dates(place)} class="stop-address">{event_dates(place)}</div>
          <div :if={place.blurb} class="stop-blurb">{place.blurb}</div>
          <div :if={place.poet_rating} class="stop-pick">
            <span class="stars">{String.duplicate("★", place.poet_rating)}</span>
            {@poet.name}'s pick
          </div>
          <a :if={place.source_url} class="book-url" href={place.source_url}>{place.source_url}</a>
        </div>
      </div>
    </section>

    <section :if={@chapter.finds != []} class="book-gazetteer">
      <p class="book-kicker">Chapter {@chapter.number}</p>
      <h2 class="book-h">Finds from {@chapter.title}</h2>
      <div
        :for={{find, i} <- Enum.with_index(@chapter.finds, 1)}
        class="book-stop"
        style={"--stamp-c: #{NotebookComponents.find_color(find.kind)}"}
      >
        <div class="stop-n">{i}</div>
        <div>
          <span class="stop-name">{find.name}</span>
          <span class="stop-cat">{GuideComponents.humanize_category(find.kind)}</span>
          <div :if={find.blurb} class="stop-blurb">{find.blurb}</div>
          <div :if={find.poet_rating} class="stop-pick">
            <span class="stars">{String.duplicate("★", find.poet_rating)}</span>
            {@poet.name}'s pick
          </div>
          <a :if={find.url} class="book-url" href={find.url}>{find.url}</a>
        </div>
      </div>
    </section>
    """
  end

  defp event_dates(%Place{} = place), do: Place.date_range(place)
  defp event_dates(_place), do: nil

  attr :index, :map, required: true
  attr :poet, :map, required: true

  def index_pages(assigns) do
    ~H"""
    <section class="book-index" id="book-index">
      <p class="book-kicker">Index</p>
      <h2 class="book-h">Where to find things</h2>

      <div :if={@index.places != []} class="idx-section">
        <h3>Places</h3>
        <ul>
          <li :for={e <- @index.places} class="idx-entry">
            {e.term}
            <.refs refs={e.refs} />
          </li>
        </ul>
      </div>

      <div :if={@index.poems != []} class="idx-section">
        <h3>Poems</h3>
        <ul>
          <li :for={e <- @index.poems} class="idx-entry">
            {e.term}
            <.refs refs={[e.ref]} />
          </li>
        </ul>
      </div>

      <div :if={@index.topics != []} class="idx-section">
        <h3>Excursions</h3>
        <ul>
          <li :for={e <- @index.topics} class="idx-entry">
            {e.term}
            <.refs refs={e.refs} />
          </li>
        </ul>
      </div>

      <div :if={@index.books != []} class="idx-section">
        <h3>What {@poet.name} was reading</h3>
        <ul>
          <li :for={b <- @index.books} class="idx-entry">
            {b.term}<span :if={b.author} class="idx-author">, {b.author}</span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :refs, :list, required: true

  defp refs(assigns) do
    ~H"""
    <a :for={r <- @refs} href={"##{r.anchor}"} class="idx-ref">day {day_of(r)}</a>
    """
  end

  # The index carries the anchor and date; the day number is on the page
  # itself, so the anchor's date is what a reader without page numbers gets.
  defp day_of(%{date: %Date{} = d}), do: Calendar.strftime(d, "%b %-d")

  attr :manuscript, :map, required: true
  attr :edition, :map, default: nil
  attr :poet, :map, required: true

  def colophon(assigns) do
    ~H"""
    <section class="book-colophon" id="book-colophon">
      <p>
        Written by {@manuscript.colophon.poet_name}, a Traveling Poet,<br />
        {date_range(@manuscript.from, @manuscript.to)}.
      </p>
      <p>
        {days_label(@manuscript.entry_count)}<span :if={@manuscript.colophon.chapter_count > 0}>,
          {@manuscript.colophon.chapter_count} {if @manuscript.colophon.chapter_count == 1,
            do: "chapter",
            else: "chapters"}</span>.
      </p>
      <p :if={@edition && @edition.composed_at}>
        The dedication, foreword, chapter openings, epilogue and chosen lines were
        composed by {@poet.name} for this edition on {Calendar.strftime(
          @edition.composed_at,
          "%B %-d, %Y"
        )}. The journal is as it was written.
      </p>
      <p>
        Every drawing was made from a real photograph and says which one.
        The places are the poet's own picks; the ratings are its opinion, not a review score.
      </p>
      <p>
        The journal continues at
        <a class="book-url" href={@manuscript.colophon.journal_url}>
          {@manuscript.colophon.journal_url}
        </a>
      </p>
      <p>
        {@manuscript.colophon.site_url} · printed {Calendar.strftime(
          @manuscript.colophon.generated_at,
          "%B %-d, %Y"
        )}
      </p>
    </section>
    """
  end

  attr :size, :string, required: true
  attr :size_key, :string, required: true
  attr :sizes, :list, required: true
  attr :has_composed, :boolean, default: false
  attr :plain, :boolean, default: true
  attr :composing, :boolean, default: false
  attr :poet, :map, required: true

  @doc "Print, paper size, edition, back: on screen only."
  def toolbar(assigns) do
    ~H"""
    <div class="book-toolbar no-print" id="book-toolbar">
      <span id="book-status" class="book-status-busy">Laying out your book</span>
      <span :if={@composing} class="book-toolbar-note" id="book-composing-note">
        {@poet.name} is composing a new edition
      </span>
      <%= if @has_composed do %>
        <a
          href={~p"/journal/book?#{[size: @size_key]}"}
          class={!@plain && "active"}
          id="edition-composed"
          title={"With the words #{@poet.name} composed for the book"}
        >
          Composed
        </a>
        <a
          href={~p"/journal/book?#{[size: @size_key, edition: "plain"]}"}
          class={@plain && "active"}
          id="edition-plain"
          title="The journal as it was written"
        >
          As written
        </a>
      <% end %>
      <a
        :for={{key, label} <- @sizes}
        href={~p"/journal/book?#{size_params(key, @plain and @has_composed)}"}
        class={label == @size && "active"}
        title={"Paper size #{label}"}
      >
        {label}
      </a>
      <button type="button" id="book-print" disabled>Print / Save as PDF</button>
      <a href={~p"/journal"} title="Back to the journal">Journal</a>
    </div>
    """
  end

  defp size_params(key, true), do: [size: key, edition: "plain"]
  defp size_params(key, false), do: [size: key]

  defp date_range(nil, _to), do: ""
  defp date_range(%Date{} = from, %Date{} = to) when from == to, do: long_date(from)

  defp date_range(%Date{} = from, %Date{} = to) do
    if from.year == to.year,
      do: "#{Calendar.strftime(from, "%B %-d")} to #{long_date(to)}",
      else: "#{long_date(from)} to #{long_date(to)}"
  end

  defp long_date(%Date{} = d), do: Calendar.strftime(d, "%B %-d, %Y")
end
