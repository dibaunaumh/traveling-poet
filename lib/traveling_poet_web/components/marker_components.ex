defmodule TravelingPoetWeb.MarkerComponents do
  @moduledoc """
  The feedback marker tray on the owner's journal page, and the icon each
  marker kind wears. Icons live here rather than in the schema so Tailwind
  (which scans only the web layer) generates the `hero-*` classes.
  """

  use Phoenix.Component

  import TravelingPoetWeb.CoreComponents, only: [icon: 1]

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

  def icons, do: @icons

  @doc "The icon map as JSON, for the browser hook that draws margin pins."
  def icons_json, do: Jason.encode!(@icons)

  attr :active, :string, default: nil

  def marker_tray(assigns) do
    assigns = assign(assigns, :specs, Marker.specs())

    ~H"""
    <div id="marker-tray" class="marker-tray" role="toolbar" aria-label="Feedback markers">
      <button
        :for={{kind, spec} <- @specs}
        type="button"
        phx-click="pick_marker"
        phx-value-kind={kind}
        class={["marker-btn", "marker-#{kind}", @active == kind && "is-active"]}
        title={spec.meaning}
        aria-pressed={to_string(@active == kind)}
      >
        <.icon name={icons()[kind]} class="size-4" />
        <span>{spec.label}</span>
      </button>
      <span class="marker-tray-hint">{hint(@active)}</span>
    </div>
    """
  end

  defp hint(nil), do: "Pick a marker, then select text or tap a paragraph."

  defp hint(kind),
    do:
      "Select text or tap a paragraph to mark it #{Marker.label(kind)}. Tap a mark to remove it."
end
