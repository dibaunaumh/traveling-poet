defmodule TravelingPoetWeb.ProductTour do
  @moduledoc """
  The product tour: a slideshow of short, silent clips of the real app, one
  feature each, shown while a new reader waits for the first page (card-89).

  Setup plus the first entry take 10 to 15 minutes, and readers who watched
  an empty screen gave up. So the wait teaches the product instead, in order
  of what a reader gets the most out of, and long enough that it rarely runs
  out before the page lands. `?tour=1` on the journal opens it any time, and
  Settings links there.

  Each slide's clip lives at `priv/static/images/tour/<id>.mp4` with a poster
  at `<id>.jpg` (recorded in the iPhone Simulator; re-record when a screen
  changes; plan-days, share and stay were recorded in headless Chrome at
  iPhone size with the app's User-Agent, from a seeded local server, before
  those features reached production). A slide whose files are missing shows
  its text alone.
  """
  use Phoenix.Component
  use Gettext, backend: TravelingPoetWeb.Gettext

  # Built per call, not at compile time, so each reader gets their language.
  defp slide_copy do
    [
      %{
        id: "daily-page",
        title: dgettext("onboarding", "A page every day"),
        why:
          dgettext(
            "onboarding",
            "Your poet travels a little each day and writes you one illustrated page: a story, a drawing, and the real sources behind both."
          ),
        how:
          dgettext(
            "onboarding",
            "Open Journal. The newest page is on top, and earlier ones are a tap away."
          )
      },
      %{
        id: "places",
        title: dgettext("onboarding", "The places in it"),
        why:
          dgettext(
            "onboarding",
            "Every page comes with the places your poet visited, and what to see, eat or do there."
          ),
        how: dgettext("onboarding", "Turn to the Places side of the page.")
      },
      %{
        id: "chat",
        title: dgettext("onboarding", "Talk to your poet"),
        why:
          dgettext(
            "onboarding",
            "Ask where it is heading, suggest a place, or ask about something it wrote. It answers in its own voice."
          ),
        how: dgettext("onboarding", "Tap Chat.")
      },
      %{
        id: "markers",
        title: dgettext("onboarding", "Point at a passage"),
        why:
          dgettext(
            "onboarding",
            "Mark a line as interesting or beautiful, or ask for a change. Your poet revises the page and learns what you like."
          ),
        how:
          dgettext("onboarding", "Tap a word or select a passage on a page, then choose a mark.")
      },
      %{
        id: "notifications",
        title: dgettext("onboarding", "Know when it lands"),
        why:
          dgettext(
            "onboarding",
            "Get each new page as a notification or an email, so the daily ritual comes to you."
          ),
        how: dgettext("onboarding", "Settings, Notifications.")
      },
      %{
        id: "listen",
        title: dgettext("onboarding", "Listen to the page"),
        why:
          dgettext(
            "onboarding",
            "Every page can be read to you, about five minutes, for the walk or the commute. The first press on a page takes a few seconds while it is read. The email brings the link too."
          ),
        how: dgettext("onboarding", "Press the ring under the page's title.")
      },
      %{
        id: "guide",
        title: dgettext("onboarding", "Your trip guide"),
        why:
          dgettext(
            "onboarding",
            "Every place your poet found, on a map, in a list, or as an itinerary you could follow on a real trip."
          ),
        how: dgettext("onboarding", "Tap Guide.")
      },
      %{
        id: "save",
        title: dgettext("onboarding", "Save what you would visit"),
        why:
          dgettext(
            "onboarding",
            "Keep the places and finds you want to see for yourself, in one list on the map."
          ),
        how: dgettext("onboarding", "Tap Save on a place, then Saved in the Guide.")
      },
      %{
        id: "plan-days",
        title: dgettext("onboarding", "Plan my days"),
        why:
          dgettext(
            "onboarding",
            "Turn your saved places into days by neighbourhood, coffee first and dinner last, with opening hours, what to book ahead, and a walking route in Google Maps."
          ),
        how: dgettext("onboarding", "Guide, Saved, then Plan my days.")
      },
      %{
        id: "share",
        title: dgettext("onboarding", "Plan it with friends"),
        why:
          dgettext(
            "onboarding",
            "Share your saved places with the people you travel with, by one private link they can open without an account, or as a map in Google Maps."
          ),
        how: dgettext("onboarding", "Guide, Saved, then Share this list with friends.")
      },
      %{
        id: "tastes",
        title: dgettext("onboarding", "What you travel for"),
        why:
          dgettext(
            "onboarding",
            "Tell your poet what you love, from food to music to mountains, and it steers the journey toward it. Now and then it asks what you have been into lately."
          ),
        how: dgettext("onboarding", "Settings, Tastes. Or just tell your poet in chat.")
      },
      %{
        id: "excursions",
        title: dgettext("onboarding", "Excursion days"),
        why:
          dgettext(
            "onboarding",
            "Every week or so your poet takes a day off the road to visit a place for one of your topics, a festival, a lab, a conference, and brings back finds."
          ),
        how: dgettext("onboarding", "Settings, Topics.")
      },
      %{
        id: "discover",
        title: dgettext("onboarding", "Discover other poets"),
        why:
          dgettext(
            "onboarding",
            "See where every poet is on a world map, and read their newest pages."
          ),
        how: dgettext("onboarding", "Tap Discover.")
      },
      %{
        id: "village",
        title: dgettext("onboarding", "The global village"),
        why:
          dgettext(
            "onboarding",
            "Every place all the poets have found, sorted by subject, from food to festivals."
          ),
        how: dgettext("onboarding", "Discover, then Village.")
      },
      %{
        id: "scout",
        title: dgettext("onboarding", "Plan a real trip"),
        why:
          dgettext(
            "onboarding",
            "Switch your poet to Trip Scout and it travels ahead of you through the stops of your itinerary, so you arrive knowing where to go."
          ),
        how: dgettext("onboarding", "Settings, Journey.")
      },
      %{
        id: "stay",
        title: dgettext("onboarding", "Where to stay"),
        why:
          dgettext(
            "onboarding",
            "On a Trip Scout trip your poet weighs the neighbourhoods of each city and picks one, then you can compare hotels by price, rating and how close they are to its places."
          ),
        how: dgettext("onboarding", "Open the Where to stay page of that day.")
      },
      %{
        id: "calendar",
        title: dgettext("onboarding", "Trips from your calendar"),
        why:
          dgettext(
            "onboarding",
            "Connect Google Calendar and your poet notices an upcoming trip and offers to scout it for you."
          ),
        how: dgettext("onboarding", "Settings, Trips.")
      },
      %{
        id: "book",
        title: dgettext("onboarding", "Your journal as a book"),
        why:
          dgettext(
            "onboarding",
            "Turn the whole journey into a printable book, a PDF, or a copy in Google Drive."
          ),
        how: dgettext("onboarding", "Tap Book on your journal.")
      },
      %{
        id: "voice",
        title: dgettext("onboarding", "Your poet's voice"),
        why:
          dgettext(
            "onboarding",
            "Change your poet's name, personality or writing voice whenever you like."
          ),
        how: dgettext("onboarding", "Settings, then your poet's name.")
      },
      %{
        id: "credits",
        title: dgettext("onboarding", "How credits work"),
        why:
          dgettext(
            "onboarding",
            "A day on the road uses one credit, a Trip Scout day five. You start with ten free, and can top up any time."
          ),
        how: dgettext("onboarding", "Settings, Credits.")
      }
    ]
  end

  # Which clips exist is settled at compile time (the wait screen re-renders
  # every few seconds); adding a clip recompiles this module.
  @tour_dir Path.expand("../../../priv/static/images/tour", __DIR__)
  @external_resource @tour_dir
  @present (case File.ls(@tour_dir) do
              {:ok, files} -> MapSet.new(files)
              _ -> MapSet.new()
            end)

  @doc "The slides, in tour order."
  def slides, do: Enum.map(slide_copy(), &with_media/1)

  defp with_media(%{id: id} = slide) do
    Map.merge(slide, %{video: asset(id, "mp4"), poster: asset(id, "jpg")})
  end

  # Only files that exist, so a slide recorded later simply shows its text.
  defp asset(id, ext) do
    file = "#{id}.#{ext}"

    if MapSet.member?(@present, file),
      do: TravelingPoetWeb.Endpoint.static_path("/images/tour/" <> file)
  end

  attr :id, :string, default: "product-tour"
  attr :status, :string, default: nil, doc: "a line on how the wait is going"
  attr :ready, :boolean, default: false, doc: "the first page has landed"
  attr :closable, :boolean, default: false

  def product_tour(assigns) do
    assigns = assign(assigns, :slides, slides())

    ~H"""
    <section
      id={@id}
      class="product-tour"
      aria-roledescription="carousel"
      aria-label={dgettext("onboarding", "What you can do")}
    >
      <div :if={@ready} id={"#{@id}-ready"} class="product-tour-ready" role="status">
        <span>{dgettext("onboarding", "Your first page is here.")}</span>
        <button type="button" phx-click="close_tour" class="btn btn-primary btn-sm">
          {dgettext("onboarding", "Read it")}
        </button>
      </div>
      <header class="product-tour-head">
        <div>
          <h3 class="font-semibold">
            {if @closable,
              do: dgettext("onboarding", "A look around"),
              else: dgettext("onboarding", "While you wait, a look around")}
          </h3>
          <p :if={@status && !@ready} class="text-sm opacity-70">{@status}</p>
        </div>
        <button
          :if={@closable && !@ready}
          type="button"
          phx-click="close_tour"
          class="btn btn-ghost btn-sm"
          aria-label={dgettext("onboarding", "Close the tour")}
        >
          {dgettext("onboarding", "Close")}
        </button>
      </header>

      <div id={"#{@id}-stage"} phx-hook="ProductTour" phx-update="ignore" class="product-tour-stage">
        <ol class="product-tour-slides">
          <li
            :for={{slide, i} <- Enum.with_index(@slides)}
            id={"tour-slide-#{slide.id}"}
            class="product-tour-slide"
            data-index={i}
            aria-roledescription="slide"
            aria-label={dgettext("onboarding", "%{n} of %{total}", n: i + 1, total: length(@slides))}
            hidden={i != 0}
          >
            <div :if={slide.video || slide.poster} class="product-tour-media">
              <video
                :if={slide.video}
                muted
                playsinline
                loop
                preload="none"
                poster={slide.poster}
                data-src={slide.video}
              ></video>
              <img :if={!slide.video && slide.poster} src={slide.poster} alt="" />
            </div>
            <div class="product-tour-text">
              <p class="product-tour-count">
                {dgettext("onboarding", "%{n} of %{total}", n: i + 1, total: length(@slides))}
              </p>
              <h4>{slide.title}</h4>
              <p>{slide.why}</p>
              <p class="product-tour-how">{slide.how}</p>
            </div>
          </li>
        </ol>
        <nav class="product-tour-nav" aria-label={dgettext("onboarding", "Tour")}>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            data-tour-prev
            aria-label={dgettext("onboarding", "Previous")}
          >
            {dgettext("onboarding", "Previous")}
          </button>
          <div class="product-tour-dots">
            <button
              :for={{slide, i} <- Enum.with_index(@slides)}
              type="button"
              data-tour-go={i}
              aria-label={slide.title}
              aria-current={i == 0 && "true"}
            ></button>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm"
            data-tour-next
            aria-label={dgettext("onboarding", "Next")}
          >
            {dgettext("onboarding", "Next")}
          </button>
        </nav>
      </div>
    </section>
    """
  end
end
