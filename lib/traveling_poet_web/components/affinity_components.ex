defmodule TravelingPoetWeb.AffinityComponents do
  @moduledoc """
  A reader's taste profile as a picture (card-37): the subject tree laid out
  flat (`Affinity.Layout`), one faint region per subject, and a dot per
  topic the reader has leaned toward (green) or away from (red), stronger
  the stronger the signal. Server-rendered SVG, no script.
  """

  use Phoenix.Component

  alias TravelingPoet.Affinity.Layout

  # The village's subject hues (assets/js/village.js), so a subject looks the
  # same wherever the tree is drawn.
  @hues %{
    "art" => 330,
    "crafts-and-design" => 28,
    "music-and-performance" => 275,
    "literature-and-ideas" => 215,
    "history-and-heritage" => 45,
    "faith-and-spirit" => 250,
    "architecture-and-cityscape" => 195,
    "nature-and-outdoors" => 125,
    "food-and-drink" => 8,
    "markets-and-shopping" => 58,
    "festivals-and-community" => 300,
    "science-industry-and-play" => 170
  }

  # Below this a subject is noise, not a leaning.
  @min_dot 0.3

  attr :profile, :list, required: true, doc: "`Affinity.profile/1`: [%{path, names, score}]"
  attr :id, :string, default: "taste-map"

  def taste_map(assigns) do
    %{regions: regions, points: points} = Layout.layout()
    dots = dots(assigns.profile, points)

    assigns =
      assign(assigns,
        regions: regions,
        dots: dots,
        width: Layout.width(),
        height: Layout.height()
      )

    ~H"""
    <figure id={@id} class="taste-map">
      <svg
        viewBox={"0 0 #{@width} #{@height}"}
        role="img"
        aria-label="Your subjects on the map of everything the poets write about"
      >
        <g :for={r <- @regions}>
          <rect
            x={r.x}
            y={r.y}
            width={r.w}
            height={r.h}
            class="taste-map-region"
            style={"--hue: #{hue(r.path)}"}
          />
          <text :if={label(r)} x={r.x + 10} y={r.y + 26} class="taste-map-label">{label(r)}</text>
        </g>
        <circle
          :for={d <- @dots}
          cx={d.x}
          cy={d.y}
          r={d.r}
          class={["taste-map-dot", d.for? && "is-for", !d.for? && "is-against"]}
          style={"opacity: #{d.opacity}"}
        >
          <title>{d.title}</title>
        </circle>
      </svg>
      <figcaption class="text-xs opacity-60 mt-1">
        <span class="taste-map-key is-for"></span>
        leaning toward <span class="taste-map-key is-against ml-3"></span>
        leaning away
      </figcaption>
    </figure>
    """
  end

  defp dots(profile, points) do
    shown = Enum.filter(profile, &(abs(&1.score) >= @min_dot and Map.has_key?(points, &1.path)))
    top = shown |> Enum.map(&abs(&1.score)) |> Enum.max(fn -> 1.0 end)

    # weakest first, so the strongest dots are drawn on top
    shown
    |> Enum.sort_by(&abs(&1.score))
    |> Enum.map(fn s ->
      {x, y} = Map.fetch!(points, s.path)
      strength = abs(s.score) / top
      [subject, _group, topic] = s.names

      %{
        x: Float.round(x, 1),
        y: Float.round(y, 1),
        r: Float.round(6 + 10 * strength, 1),
        opacity: Float.round(0.3 + 0.7 * strength, 2),
        for?: s.score > 0,
        title: "#{topic} (#{subject}): #{if s.score > 0, do: "toward", else: "away"}"
      }
    end)
  end

  # A subject's name, or its first word when the whole name would overflow
  # its region ("Festivals" for "Festivals & community"); none in a sliver.
  defp label(%{name: name, w: w}) do
    fits = fn text -> String.length(text) * 10.5 <= w - 20 end
    short = name |> String.split([" ", ","]) |> hd()

    cond do
      fits.(name) -> name
      fits.(short) -> short
      true -> nil
    end
  end

  defp hue(slug), do: Map.get(@hues, slug, 200)
end
