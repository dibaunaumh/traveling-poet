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

  import TravelingPoetWeb.CoreComponents, only: [icon: 1]

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
    "other" => "hero-chat-bubble-bottom-center-text-mini"
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
  defp meaning(kind), do: (Marker.spec(kind) || %{meaning: kind}).meaning

  # Push the choice and close the menu; <details> does not close itself.
  defp pick(kind) do
    JS.push("pick_marker", value: %{kind: kind})
    |> JS.remove_attribute("open", to: "#marker-menu")
  end
end
