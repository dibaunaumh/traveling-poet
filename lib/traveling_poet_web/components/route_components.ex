defmodule TravelingPoetWeb.RouteComponents do
  @moduledoc """
  The drawing of an excursion journey: the topic, the venues it went to, and
  what they gave back. Inline SVG laid out by `Topics.Route`, in the
  notebook's hand, so it needs no map, no tiles and no JavaScript.

  A topic has no coordinates; this is what takes the map's place on an
  excursion entry and in the guide.
  """

  use TravelingPoetWeb, :html

  attr :diagram, :map, required: true, doc: "from Topics.Route.build/4"
  attr :title, :string, default: "The journey so far"
  attr :empty, :string, default: "No excursions yet."
  attr :rest, :global

  def excursion_route(assigns) do
    ~H"""
    <figure class="route-figure" {@rest}>
      <svg
        class={["route-svg", "is-#{@diagram.layout}"]}
        viewBox={"0 0 #{@diagram.width} #{@diagram.height}"}
        preserveAspectRatio="xMidYMid meet"
        role="img"
        aria-label={route_label(@diagram)}
      >
        <path :for={edge <- @diagram.edges} d={edge.d} class={"route-edge route-#{edge.kind}"} />

        <g class="route-root">
          <circle
            :if={@diagram.root.ring?}
            cx={@diagram.root.x}
            cy={@diagram.root.y}
            r="52"
            class="route-root-ring"
          />
          <text
            x={@diagram.root.x}
            y={@diagram.root.y - if(@diagram.root.ring?, do: 4, else: 0)}
            class={["route-root-label", !@diagram.root.ring? && "is-left"]}
          >
            {@diagram.root.label}
          </text>
          <text
            :if={@diagram.root.ring?}
            x={@diagram.root.x}
            y={@diagram.root.y + 18}
            class="route-root-kicker"
          >
            topic
          </text>
        </g>

        <g :for={venue <- @diagram.venues} class={["route-venue", venue.current? && "is-current"]}>
          <circle cx={venue.x} cy={venue.y} r="13" class="route-node" />
          <text x={venue.x} y={venue.y + 5} class="route-node-n">{venue.n}</text>
          <.route_text
            x={venue.label_x}
            y={venue.label_y}
            class="route-venue-label"
            label={venue.label}
            href={venue.href}
          />
          <text :if={venue.sub} x={venue.label_x} y={venue.sub_y} class="route-venue-date">
            {venue.sub}
          </text>

          <g :for={find <- venue.finds} class="route-find">
            <circle cx={find.dot_x} cy={find.y} r="5" class="route-find-dot" />
            <.route_text
              x={find.x}
              y={find.y + 4}
              class="route-find-label"
              label={find.label}
              href={find.href}
            />
          </g>
        </g>
      </svg>
      <figcaption class="notebook-caption">
        <span :if={@diagram.venues == []}>{@empty}</span>
        <span :if={@diagram.venues != []}>{@title}</span>
      </figcaption>
    </figure>
    """
  end

  attr :x, :integer, required: true
  attr :y, :integer, required: true
  attr :class, :string, required: true
  attr :label, :string, required: true
  attr :href, :string, default: nil

  # A label, linked when the poet gave a page for it. The anchor is inside
  # the SVG, so it needs the xlink-free SVG2 form plus the usual rel.
  defp route_text(assigns) do
    ~H"""
    <a :if={@href} href={@href} target="_blank" rel="noopener noreferrer nofollow">
      <text x={@x} y={@y} class={[@class, "is-link"]}>{@label}</text>
    </a>
    <text :if={is_nil(@href)} x={@x} y={@y} class={@class}>{@label}</text>
    """
  end

  defp route_label(diagram) do
    case diagram.venues do
      [] -> "#{diagram.root.label}: no excursions yet"
      venues -> "#{diagram.root.label}: " <> Enum.map_join(venues, ", then ", & &1.label)
    end
  end
end
