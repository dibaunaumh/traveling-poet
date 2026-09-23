defmodule TravelingPoetWeb.RouteComponents do
  @moduledoc """
  The drawing of an excursion journey: the topic, the destinations it went to, and
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

        <g
          :for={destination <- @diagram.destinations}
          class={["route-destination", destination.current? && "is-current"]}
        >
          <circle cx={destination.x} cy={destination.y} r="13" class="route-node" />
          <text x={destination.x} y={destination.y + 5} class="route-node-n">{destination.n}</text>
          <.route_text
            x={destination.label_x}
            y={destination.label_y}
            class="route-destination-label"
            lines={destination.lines}
            href={destination.href}
          />
          <text
            :if={destination.sub}
            x={destination.label_x}
            y={destination.sub_y}
            class="route-destination-date"
          >
            {destination.sub}
          </text>

          <g :for={find <- destination.finds} class="route-find">
            <circle cx={find.dot_x} cy={find.y} r="5" class="route-find-dot" />
            <.route_text
              x={find.x}
              y={find.y + 4}
              class="route-find-label"
              lines={[find.label]}
              href={find.href}
            />
          </g>
        </g>
      </svg>
      <figcaption class="notebook-caption">
        <span :if={@diagram.destinations == []}>{@empty}</span>
        <span :if={@diagram.destinations != []}>{@title}</span>
      </figcaption>
    </figure>
    """
  end

  attr :x, :integer, required: true
  attr :y, :integer, required: true
  attr :class, :string, required: true
  attr :lines, :list, required: true, doc: "the label, already broken into lines"
  attr :href, :string, default: nil

  # A label over one or more lines, linked when the poet gave a page for it.
  # The anchor is inside the SVG, so it needs the xlink-free SVG2 form plus
  # the usual rel.
  defp route_text(assigns) do
    ~H"""
    <a :if={@href} href={@href} target="_blank" rel="noopener noreferrer nofollow">
      <text x={@x} y={@y} class={[@class, "is-link"]}>
        <tspan :for={{line, i} <- Enum.with_index(@lines)} x={@x} dy={(i == 0 && 0) || 18}>
          {line}
        </tspan>
      </text>
    </a>
    <text :if={is_nil(@href)} x={@x} y={@y} class={@class}>
      <tspan :for={{line, i} <- Enum.with_index(@lines)} x={@x} dy={(i == 0 && 0) || 18}>
        {line}
      </tspan>
    </text>
    """
  end

  defp route_label(diagram) do
    case diagram.destinations do
      [] ->
        "#{diagram.root.label}: no excursions yet"

      destinations ->
        "#{diagram.root.label}: " <> Enum.map_join(destinations, ", then ", & &1.label)
    end
  end
end
