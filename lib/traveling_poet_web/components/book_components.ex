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
    <section
      class={["book-cover", @manuscript.cover_drawing && "book-cover-drawn"]}
      id="book-cover"
    >
      <div class="book-wordmark">Traveling <em>Poet</em></div>
      <h1>{@manuscript.title}</h1>
      <p class="book-subtitle">{@manuscript.subtitle}</p>
      <figure :if={@manuscript.cover_drawing} class="book-cover-drawing">
        <img
          src={~p"/media/#{@manuscript.cover_drawing.id}"}
          alt={@manuscript.cover_drawing.alt_text || dgettext("book", "a drawing from the journey")}
        />
      </figure>
      <p class="book-route book-route-count">
        {days_label(@manuscript.entry_count)}
        <span :if={@manuscript.colophon.chapter_count > 1}>
          {dgettext("book", "in %{count} places", count: @manuscript.colophon.chapter_count)}
        </span>
      </p>
    </section>
    """
  end

  attr :manuscript, :map, required: true
  attr :companion, :string, default: nil

  @doc """
  The poet as the book's author, on the page after the cover: its portrait,
  temperament, interests, what it was reading, where it set out from and
  for whom. Only what the poet's profile and the journey actually hold.
  """
  def author_page(assigns) do
    poet = assigns.manuscript.poet
    first = List.first(assigns.manuscript.chapters)

    assigns =
      assign(assigns,
        poet: poet,
        interests: Enum.reject(poet.interests || [], &(String.trim(&1) == "")),
        reading: reading_items(poet),
        set_out_from: first && short_place(first.title),
        set_out_on: assigns.manuscript.from
      )

    ~H"""
    <section class="book-author" id="book-author">
      <p class="book-kicker">{dgettext("book", "About the author")}</p>
      <img
        :if={@poet.avatar_url}
        src={@poet.avatar_url}
        alt={@poet.name}
        class="book-author-portrait"
      />
      <h2 class="book-author-name">{@poet.name}</h2>
      <p class="book-author-role">
        {if @companion,
          do: dgettext("book", "a Traveling Poet, writing for %{companion}", companion: @companion),
          else: dgettext("book", "a Traveling Poet")}
      </p>
      <p :if={present?(@poet.personality)} class="book-author-temperament">
        {@poet.personality}
      </p>
      <dl class="book-author-facts">
        <div :if={@interests != []}>
          <dt>{dgettext("book", "Drawn to")}</dt>
          <dd>{Enum.join(@interests, ", ")}</dd>
        </div>
        <div :if={@reading != []}>
          <dt>{dgettext("book", "Reading")}</dt>
          <dd>
            <span :for={{book, i} <- Enum.with_index(@reading)}>
              <span :if={i > 0}>; </span><.book_title book={book} />
            </span>
          </dd>
        </div>
        <div :if={@set_out_from && @set_out_on}>
          <dt>{dgettext("book", "Set out")}</dt>
          <dd>
            {dgettext("book", "from %{place}, %{date}",
              place: @set_out_from,
              date: TravelingPoet.Locale.format_date(@set_out_on, :long)
            )}
          </dd>
        </div>
        <div :if={length(@manuscript.chapters) > 1}>
          <dt>{dgettext("book", "Route")}</dt>
          <dd>{route_line(@manuscript)}</dd>
        </div>
      </dl>
    </section>
    """
  end

  attr :book, :map, required: true

  # "<em>Title</em> by Author": one sentence, so the author's side can move
  defp book_title(%{book: book} = assigns) do
    if present?(book["author"]) do
      ~H"""
      <.rich text={
        dgettext("book", "%{title} by %{author}", title: marker(:title), author: @book["author"])
      }>
        <:part name="title"><em>{@book["title"]}</em></:part>
      </.rich>
      """
    else
      ~H"""
      <em>{@book["title"]}</em>
      """
    end
  end

  defp reading_items(%{currently_reading: %{"items" => items}}) when is_list(items),
    do: Enum.filter(items, &(is_map(&1) and present?(&1["title"])))

  defp reading_items(_poet), do: []

  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false

  defp route_line(%{chapters: chapters}) do
    names = Enum.map(chapters, &short_place(&1.title))

    case Enum.split(names, @route_max) do
      {shown, []} ->
        Enum.join(shown, " · ")

      {shown, rest} ->
        Enum.join(shown ++ [dgettext("book", "and %{count} more", count: length(rest))], " · ")
    end
  end

  # "Lisbon, Portugal" reads as "Lisbon" on a cover line of eight.
  defp short_place(name) when is_binary(name),
    do: name |> String.split(",") |> hd() |> String.trim()

  defp short_place(other), do: other

  defp days_label(n), do: dngettext("book", "One day", "%{count} days", n)

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
        {signed_day(@poet.name, @day.number, @day.entry.place_name)}
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
      <p class="book-kicker">{dgettext("book", "Contents")}</p>
      <h2 class="book-h">{dgettext("book", "The journey")}</h2>
      <p :if={@manuscript.chapters == []} class="book-muted">
        {dgettext("book", "No pages yet. The first one lands the morning after the poet sets out.")}
      </p>
      <ol>
        <li :if={@matter && @matter.foreword} class="toc-chapter">
          <a href="#book-foreword"><span class="toc-title">{dgettext("book", "Foreword")}</span></a>
        </li>
        <li :for={ch <- @manuscript.chapters} class="toc-chapter">
          <a href={"##{ch.anchor}"}>
            <span class="toc-title">{ch.number}. {ch.title}</span>
          </a>
          <ol class="toc-days">
            <li :for={d <- ch.days}>
              <a href={"##{d.anchor}"}>
                <span class="toc-day">{dgettext("book", "Day %{n}", n: d.number)}</span>
                <span class="toc-title">{entry_title(d.entry)}</span>
              </a>
            </li>
          </ol>
        </li>
        <li :if={@matter && @matter.epilogue} class="toc-chapter">
          <a href="#book-epilogue"><span class="toc-title">{dgettext("book", "Epilogue")}</span></a>
        </li>
        <li :if={@manuscript.chapters != []} class="toc-chapter">
          <a href="#book-index"><span class="toc-title">{dgettext("book", "Index")}</span></a>
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
      <p class="book-kicker">{dgettext("book", "Chapter %{n}", n: @chapter.number)}</p>
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
        <span class="notebook-day">{dgettext("book", "Day %{n}", n: @day.number)}</span>
        <span class="notebook-date">{TravelingPoet.Locale.format_date(@day.date, :weekday_long)}</span>
        <h2 class="notebook-title">{entry_title(@entry)}</h2>
      </header>

      <div :if={@excursion} class="book-ticket">
        <div class="ticket-kicker">{dgettext("book", "A day off the road")}</div>
        <div class="ticket-topic">
          {dgettext("book", "An excursion into %{topic}", topic: excursion_label(@entry))}
        </div>
        <div :if={@excursion.destination_name}>{@excursion.destination_name}</div>
      </div>

      <.drawing :for={m <- @drawings} media={m} />

      <.section :for={s <- @prose} section={s} spot_media={@spot_media} />

      <.sources list={@day.sources} />

      <p class="book-day-foot">
        <.rich text={dgettext("book", "Read online: %{url}", url: marker(:url))}>
          <:part name="url"><a class="book-url" href={@day.url}>{@day.url}</a></:part>
        </.rich>
      </p>
    </article>

    <section :for={poem <- @poems} class="book-poem">
      <h3 class="notebook-section-title">{poem.title || dgettext("book", "A poem")}</h3>
      <div class="book-poem-body prose">{raw_markdown(poem.body, @spot_media, [])}</div>
      <p class="book-poem-foot">
        {signed_day(@poet.name, @day.number, @entry.place_name)}
      </p>
    </section>
    """
  end

  # "Ada, day 3, Lisbon" under a poem or a chosen line
  defp signed_day(poet, n, place) when is_binary(place) and place != "",
    do: dgettext("book", "%{poet}, day %{n}, %{place}", poet: poet, n: n, place: place)

  defp signed_day(poet, n, _place), do: dgettext("book", "%{poet}, day %{n}", poet: poet, n: n)

  attr :media, :map, required: true

  # The url of what it was drawn from is in the day's sources list; the
  # caption only names it, as the journal's does.
  defp drawing(assigns) do
    ~H"""
    <figure class="taped-photo">
      <img src={~p"/media/#{@media.id}"} alt={@media.alt_text || dgettext("book", "drawing")} />
      <figcaption>
        <span :if={@media.alt_text}>{@media.alt_text}</span>
        <span :for={src <- Media.source_items(@media)} class="src">
          {dgettext("book", "Drawn from %{source}",
            source: src["label"] || dgettext("book", "the real place")
          )}
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
      <h3>{dgettext("book", "Sources")}</h3>
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
      <p class="book-kicker">{dgettext("book", "Chapter %{n}", n: @chapter.number)}</p>
      <h2 class="book-h">{dgettext("book", "Places in %{chapter}", chapter: @chapter.title)}</h2>
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
      <p class="book-kicker">{dgettext("book", "Chapter %{n}", n: @chapter.number)}</p>
      <h2 class="book-h">{dgettext("book", "Finds from %{chapter}", chapter: @chapter.title)}</h2>
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
      <p class="book-kicker">{dgettext("book", "Index")}</p>
      <h2 class="book-h">{dgettext("book", "Where to find things")}</h2>

      <div :if={@index.places != []} class="idx-section">
        <h3>{dgettext("book", "Places")}</h3>
        <ul>
          <li :for={e <- @index.places} class="idx-entry">
            {e.term}
            <.refs refs={e.refs} />
          </li>
        </ul>
      </div>

      <div :if={@index.poems != []} class="idx-section">
        <h3>{dgettext("book", "Poems")}</h3>
        <ul>
          <li :for={e <- @index.poems} class="idx-entry">
            {e.term}
            <.refs refs={[e.ref]} />
          </li>
        </ul>
      </div>

      <div :if={@index.topics != []} class="idx-section">
        <h3>{dgettext("book", "Excursions")}</h3>
        <ul>
          <li :for={e <- @index.topics} class="idx-entry">
            {e.term}
            <.refs refs={e.refs} />
          </li>
        </ul>
      </div>

      <div :if={@index.books != []} class="idx-section">
        <h3>{dgettext("book", "What %{poet} was reading", poet: @poet.name)}</h3>
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
    <a :for={r <- @refs} href={"##{r.anchor}"} class="idx-ref">{ref_label(r)}</a>
    """
  end

  defp ref_label(ref), do: dgettext("book", "day %{date}", date: day_of(ref))

  # The index carries the anchor and date; the day number is on the page
  # itself, so the anchor's date is what a reader without page numbers gets.
  defp day_of(%{date: %Date{} = d}), do: TravelingPoet.Locale.format_date(d, :short)

  attr :manuscript, :map, required: true
  attr :edition, :map, default: nil
  attr :poet, :map, required: true

  def colophon(assigns) do
    ~H"""
    <section class="book-colophon" id="book-colophon">
      <p>
        <.rich text={
          dgettext("book", "Written by %{poet}, a Traveling Poet,%{br}%{dates}.",
            poet: @manuscript.colophon.poet_name,
            br: marker(:br),
            dates: date_range(@manuscript.from, @manuscript.to)
          )
        }>
          <:part name="br"><br /></:part>
        </.rich>
      </p>
      <p>{count_line(@manuscript)}</p>
      <p :if={@edition && @edition.composed_at}>
        {dgettext(
          "book",
          "The dedication, foreword, chapter openings, epilogue and chosen lines were composed by %{poet} for this edition on %{date}. The journal is as it was written.",
          poet: @poet.name,
          date: TravelingPoet.Locale.format_date(@edition.composed_at, :long)
        )}
      </p>
      <p :if={@manuscript.cover_drawing} id="book-cover-credit">
        <.rich text={
          dgettext("book", "The cover drawing was made from %{sources}.", sources: marker(:sources))
        }>
          <:part name="sources">{cover_sources(@manuscript.cover_drawing)}</:part>
        </.rich>
      </p>
      <p>
        {dgettext(
          "book",
          "Every drawing was made from a real photograph and says which one. The places are the poet's own picks; the ratings are its opinion, not a review score."
        )}
      </p>
      <p>
        <.rich text={dgettext("book", "The journal continues at %{url}", url: marker(:url))}>
          <:part name="url">
            <a class="book-url" href={@manuscript.colophon.journal_url}>
              {@manuscript.colophon.journal_url}
            </a>
          </:part>
        </.rich>
      </p>
      <p>
        {dgettext("book", "%{site} · printed %{date}",
          site: @manuscript.colophon.site_url,
          date: TravelingPoet.Locale.format_date(@manuscript.colophon.generated_at, :long)
        )}
      </p>
    </section>
    """
  end

  # "12 days, 3 chapters."
  defp count_line(%{entry_count: days, colophon: %{chapter_count: chapters}})
       when chapters > 0,
       do:
         dgettext("book", "%{days}, %{chapters}.",
           days: days_label(days),
           chapters: dngettext("book", "%{count} chapter", "%{count} chapters", chapters)
         )

  defp count_line(%{entry_count: days}), do: dgettext("book", "%{days}.", days: days_label(days))

  attr :size, :string, required: true
  attr :size_key, :string, required: true
  attr :sizes, :list, required: true
  attr :has_composed, :boolean, default: false
  attr :plain, :boolean, default: true
  attr :composing, :boolean, default: false
  attr :pdf_enabled, :boolean, default: false
  attr :poet, :map, required: true
  attr :native, :boolean, default: false, doc: "inside the iOS app, where a page cannot print"

  @doc "Print, paper size, edition, back: on screen only."
  def toolbar(assigns) do
    ~H"""
    <div class="book-toolbar no-print" id="book-toolbar">
      <span id="book-status" class="book-status-busy">
        {dgettext("book", "Laying out your book")}
      </span>
      <span :if={@composing} class="book-toolbar-note" id="book-composing-note">
        {dgettext("book", "%{poet} is composing a new edition", poet: @poet.name)}
      </span>
      <%= if @has_composed do %>
        <a
          href={~p"/journal/book?#{[size: @size_key]}"}
          class={!@plain && "active"}
          id="edition-composed"
          title={dgettext("book", "With the words %{poet} composed for the book", poet: @poet.name)}
        >
          {dgettext("book", "Composed")}
        </a>
        <a
          href={~p"/journal/book?#{[size: @size_key, edition: "plain"]}"}
          class={@plain && "active"}
          id="edition-plain"
          title={dgettext("book", "The journal as it was written")}
        >
          {dgettext("book", "As written")}
        </a>
      <% end %>
      <a
        :for={{key, label} <- @sizes}
        href={~p"/journal/book?#{size_params(key, @plain and @has_composed)}"}
        class={label == @size && "active"}
        title={dgettext("book", "Paper size %{size}", size: label)}
      >
        {label}
      </a>
      <%!-- window.print() does nothing in the iOS app's web view; the PDF is
            the way to paper there. --%>
      <button :if={!@native} type="button" id="book-print" disabled>
        {dgettext("book", "Print")}
      </button>
      <a
        :if={@pdf_enabled}
        href={~p"/settings#book"}
        id="book-get-pdf"
        title={dgettext("book", "A stored PDF to download")}
      >
        {dgettext("book", "Get the PDF")}
      </a>
      <a href={~p"/journal"} title={dgettext("book", "Back to the journal")}>
        {dgettext("book", "Journal")}
      </a>
    </div>
    """
  end

  # The cover drawing's references, label and url, as the day's sources list
  # prints them: paper has no hover.
  defp cover_sources(media) do
    assigns = %{items: Media.source_items(media)}

    ~H"""
    <span :for={{src, i} <- Enum.with_index(@items)}>
      <span :if={i > 0}>, </span>{src["label"] || dgettext("book", "a photograph")}
      <a
        class="book-url"
        href={src["url"]}
      >{src["url"]}</a>
    </span>
    """
  end

  defp size_params(key, true), do: [size: key, edition: "plain"]
  defp size_params(key, false), do: [size: key]

  defp date_range(nil, _to), do: ""
  defp date_range(%Date{} = from, %Date{} = to) when from == to, do: long_date(from)

  defp date_range(%Date{} = from, %Date{} = to) do
    from =
      if from.year == to.year,
        do: TravelingPoet.Locale.format_date(from, :month_day),
        else: long_date(from)

    dgettext("journal", "%{from} to %{to}", from: from, to: long_date(to))
  end

  defp long_date(%Date{} = d), do: TravelingPoet.Locale.format_date(d, :long)
end
