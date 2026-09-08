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
    "not_creative" => "hero-arrow-path-mini"
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
        Select text or tap a paragraph to mark it {Marker.label(@active)}.
      </span>
      <details id="marker-menu" class="dropdown dropdown-end marker-menu">
        <summary
          class={["marker-menu-btn", @active && "marker-#{@active}", @active && "is-active"]}
          title={if @active, do: Marker.spec(@active).meaning, else: "Mark what you want to change"}
          aria-label="Feedback marker"
        >
          <.icon name={if @active, do: icons()[@active], else: idle_icon()} class="size-4" />
          <span :if={@active}>{Marker.label(@active)}</span>
        </summary>
        <ul class="dropdown-content marker-menu-list">
          <li class="marker-menu-title">Mark what you want to change</li>
          <li :for={{kind, spec} <- @specs}>
            <button
              type="button"
              phx-click={pick(kind)}
              class={["marker-menu-item", "marker-#{kind}", @active == kind && "is-active"]}
              title={spec.meaning}
            >
              <.icon name={icons()[kind]} class="size-4" />
              <span>{spec.label}</span>
            </button>
          </li>
          <li :if={@active}>
            <button type="button" phx-click={pick("none")} class="marker-menu-item marker-menu-off">
              <.icon name="hero-x-mark-mini" class="size-4" />
              <span>Put the marker down</span>
            </button>
          </li>
        </ul>
      </details>
    </div>
    """
  end

  # Push the choice and close the menu; <details> does not close itself.
  defp pick(kind) do
    JS.push("pick_marker", value: %{kind: kind})
    |> JS.remove_attribute("open", to: "#marker-menu")
  end
end
