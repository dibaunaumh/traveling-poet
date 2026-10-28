defmodule TravelingPoetWeb.MarkerComponents do
  @moduledoc """
  The feedback marker picker on the owner's journal page, and the icon each
  marker kind wears. Icons live here rather than in the schema so Tailwind
  (which scans only the web layer) generates the `hero-*` classes.

  One small button, not a row of seven: a row read as actions on the entry
  ("does clicking Boring mark the whole page?"). The button only picks the
  marker you hold; the marking itself happens on the text.
  """

  use Phoenix.Component
  use Gettext, backend: TravelingPoetWeb.Gettext

  import TravelingPoetWeb.CoreComponents, only: [icon: 1, input: 1]

  alias Phoenix.LiveView.JS
  alias TravelingPoet.Journal.Marker

  @icons %{
    "interesting" => "hero-sparkles-mini",
    "boring" => "hero-moon-mini",
    "more_details" => "hero-magnifying-glass-plus-mini",
    "drawing_needed" => "hero-paint-brush-mini",
    "link_needed" => "hero-link-mini",
    "beautiful" => "hero-heart-mini",
    "not_creative" => "hero-arrow-path-mini",
    "other" => "hero-chat-bubble-bottom-center-text-mini",
    "meh" => "hero-face-frown-mini",
    "inaccurate" => "hero-eye-slash-mini",
    "made_up" => "hero-no-symbol-mini"
  }

  @idle_icon "hero-pencil-square-mini"

  def icons, do: @icons
  def idle_icon, do: @idle_icon

  @doc "The icon map as JSON, for the browser hook that draws margin pins."
  def icons_json, do: Jason.encode!(@icons)

  attr :active, :string, default: nil

  def marker_menu(assigns) do
    assigns = assign(assigns, :specs, Marker.specs())

    ~H"""
    <div class="marker-menu-wrap">
      <span :if={@active} class="marker-menu-hint">
        {dgettext("journal", "Highlight text or tap a paragraph to mark it %{marker}.",
          marker: label(@active)
        )}
      </span>
      <details id="marker-menu" class="dropdown dropdown-end marker-menu">
        <summary
          class={["marker-menu-btn", @active && "marker-#{@active}", @active && "is-active"]}
          title={
            if @active,
              do: meaning(@active),
              else: dgettext("journal", "Mark what you want to change")
          }
          aria-label={dgettext("journal", "Feedback marker")}
        >
          <.icon name={if @active, do: icons()[@active], else: idle_icon()} class="size-4" />
          <span :if={@active}>{label(@active)}</span>
        </summary>
        <ul class="dropdown-content marker-menu-list">
          <li class="marker-menu-title">
            {dgettext(
              "journal",
              "Select a marker & highlight text to provide feedback to the poet"
            )}
          </li>
          <li :for={{kind, _spec} <- @specs}>
            <button
              type="button"
              phx-click={pick(kind)}
              class={["marker-menu-item", "marker-#{kind}", @active == kind && "is-active"]}
              title={meaning(kind)}
            >
              <.icon name={icons()[kind]} class="size-4" />
              <span>{label(kind)}</span>
            </button>
          </li>
          <li :if={@active}>
            <button type="button" phx-click={pick("none")} class="marker-menu-item marker-menu-off">
              <.icon name="hero-x-mark-mini" class="size-4" />
              <span>{dgettext("journal", "Put the marker down")}</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  attr :media, :map, required: true, doc: "the main drawing"
  attr :markers, :list, required: true, doc: "the entry's markers"
  attr :poet, :map, required: true
  attr :latest, :boolean, default: true, doc: "only the latest page is redrawn"
  attr :skipped, :any, default: MapSet.new(), doc: "marker ids whose note box was skipped"

  @doc """
  One quiet button under the main drawing that opens Beautiful, Meh,
  Inaccurate, Made up (a row of four inked buttons pulled the eye off the
  drawing itself).
  Each is a marker on the drawing, so it reaches the poet with the page's
  other markers once the reader has gone quiet; the three negative ones ask
  for a redraw. Inaccurate and Made up then ask what is wrong, because "the
  bridge has no road on it" is what makes the redraw right.
  """
  def drawing_feedback(assigns) do
    assigns = assign(assigns, :rating, drawing_rating(assigns.markers, assigns.media.id))

    ~H"""
    <div id={"drawing-feedback-#{@media.id}"} class="drawing-feedback">
      <details id={"drawing-menu-#{@media.id}"} class="dropdown dropdown-end drawing-feedback-menu">
        <summary
          class={["drawing-feedback-toggle", @rating && ["marker-#{@rating.kind}", "is-rated"]]}
          title={dgettext("journal", "Feedback on this drawing")}
          aria-label={dgettext("journal", "Feedback on this drawing")}
        >
          <.icon
            name={if @rating, do: icons()[@rating.kind], else: "hero-chat-bubble-left-ellipsis-mini"}
            class="size-4"
          />
          <span :if={@rating}>{label(@rating.kind)}</span>
        </summary>
        <ul class="dropdown-content marker-menu-list">
          <li class="marker-menu-title">{dgettext("journal", "How is this drawing?")}</li>
          <li :for={kind <- Marker.drawing_kinds()}>
            <button
              id={"rate-drawing-#{@media.id}-#{kind}"}
              type="button"
              phx-click={rate(@media.id, kind)}
              class={[
                "marker-menu-item",
                "marker-#{kind}",
                @rating && @rating.kind == kind && "is-active"
              ]}
              aria-pressed={to_string(!!(@rating && @rating.kind == kind))}
              title={meaning(kind)}
            >
              <.icon name={icons()[kind]} class="size-4" />
              <span>{label(kind)}</span>
            </button>
          </li>
        </ul>
      </details>
      <p :if={@rating} class="drawing-feedback-status">
        {rating_status(@rating, @poet, @latest)}
      </p>
      <p :if={@rating && @rating.note} class="drawing-feedback-note" dir="auto">
        “{@rating.note}”
      </p>
      <.form
        :let={f}
        :if={note_wanted?(@rating, @skipped)}
        for={to_form(%{"id" => @rating.id, "note" => ""}, as: :drawing_note)}
        id={"drawing-note-#{@media.id}"}
        phx-submit="drawing_note"
        class="mt-2"
      >
        <.input field={f[:id]} type="hidden" />
        <.input
          field={f[:note]}
          type="textarea"
          rows="2"
          class="page-note-input"
          placeholder={
            dgettext("journal", "What is wrong in it? For example: the bridge has no road on it.")
          }
        />
        <div class="flex items-center gap-2 mt-1">
          <button type="submit" class="btn btn-xs btn-outline">
            {dgettext("journal", "Tell %{poet}", poet: @poet.name)}
          </button>
          <button
            type="button"
            phx-click="drawing_note_skip"
            phx-value-id={@rating.id}
            class="btn btn-ghost btn-xs opacity-60"
          >
            {dgettext("journal", "Skip")}
          </button>
        </div>
      </.form>
    </div>
    """
  end

  # The reader's say on this drawing: the pending rating if there is one,
  # else the last one sent.
  defp drawing_rating(markers, media_id) do
    ratings =
      Enum.filter(markers, &(&1.media_id == media_id and &1.kind in Marker.drawing_kinds()))

    Enum.find(Enum.reverse(ratings), &is_nil(&1.sent_at)) || List.last(ratings)
  end

  defp note_wanted?(nil, _skipped), do: false

  defp note_wanted?(rating, skipped) do
    rating.kind in ~w(inaccurate made_up) and is_nil(rating.sent_at) and
      rating.note in [nil, ""] and not MapSet.member?(skipped, rating.id)
  end

  defp rating_status(%{sent_at: %DateTime{}}, poet, _latest),
    do: dgettext("journal", "Sent to %{poet}.", poet: poet.name)

  defp rating_status(%{kind: "beautiful"}, poet, _latest),
    do:
      dgettext("journal", "%{poet} will hear it once you have finished reading.", poet: poet.name)

  defp rating_status(_rating, poet, true),
    do:
      dgettext("journal", "%{poet} will redraw it once you have finished reading.",
        poet: poet.name
      )

  defp rating_status(_rating, poet, false),
    do:
      dgettext(
        "journal",
        "This page stays as it is. %{poet} will keep it in mind for the next drawings.",
        poet: poet.name
      )

  # A marker's name and meaning for the reader. `Marker.spec/1` keeps the
  # English, which the digest to the poet also reads; these are the same
  # words in the reader's language.
  @doc "A marker's name in the reader's language (the poet reads `Marker.label/1`)."
  def kind_label(kind), do: label(kind) || kind

  defp label("interesting"), do: dgettext("journal", "Interesting")
  defp label("boring"), do: dgettext("journal", "Boring")
  defp label("more_details"), do: dgettext("journal", "More details")
  defp label("drawing_needed"), do: dgettext("journal", "Drawing needed")
  defp label("link_needed"), do: dgettext("journal", "Link needed")
  defp label("beautiful"), do: dgettext("journal", "Beautiful")
  defp label("not_creative"), do: dgettext("journal", "Not creative enough")
  defp label("other"), do: dgettext("journal", "Other feedback")
  defp label("meh"), do: dgettext("journal", "Meh")
  defp label("inaccurate"), do: dgettext("journal", "Inaccurate")
  defp label("made_up"), do: dgettext("journal", "Made up")
  defp label(kind), do: Marker.label(kind)

  defp meaning("interesting"), do: dgettext("journal", "This held my attention")
  defp meaning("boring"), do: dgettext("journal", "This passage lost me")
  defp meaning("more_details"), do: dgettext("journal", "I wanted to know more here")
  defp meaning("drawing_needed"), do: dgettext("journal", "I wanted to see this")
  defp meaning("link_needed"), do: dgettext("journal", "I wanted somewhere to go from here")
  defp meaning("beautiful"), do: dgettext("journal", "This moved me")

  defp meaning("not_creative"),
    do: dgettext("journal", "This reads like anyone could have written it")

  defp meaning("other"), do: dgettext("journal", "Something else I want to tell you about this")
  defp meaning("meh"), do: dgettext("journal", "This drawing does nothing for me")
  defp meaning("inaccurate"), do: dgettext("journal", "This does not look like the real place")
  defp meaning("made_up"), do: dgettext("journal", "Something in this drawing could not exist")
  defp meaning(kind), do: (Marker.spec(kind) || %{meaning: kind}).meaning

  # Rate the drawing and close its menu.
  defp rate(media_id, kind) do
    JS.push("rate_drawing", value: %{kind: kind, media: media_id})
    |> JS.remove_attribute("open", to: "#drawing-menu-#{media_id}")
  end

  # Push the choice and close the menu; <details> does not close itself.
  defp pick(kind) do
    JS.push("pick_marker", value: %{kind: kind})
    |> JS.remove_attribute("open", to: "#marker-menu")
  end
end
