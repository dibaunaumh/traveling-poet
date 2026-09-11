defmodule TravelingPoetWeb.PublicGuideLive do
  @moduledoc """
  A public poet's trip guide, at `/p/:slug/guide`.

  Shares its state and its markup with the owner's `/guide` (GuideState and
  GuideComponents), so the two can't drift into showing different things.

  What makes this safe to expose: `Guide.list_places/2` defaults to
  `published_only`, so a draft entry's places are unreachable here exactly as
  they are for the owner; `get_public_poet_by_slug/1` is the same gate the
  public journal uses, so a private poet 404s; and place drawings are served
  by MediaController, which already authorizes on `poet.is_public`.

  The coordinate-blurring rule that applies to the landing map does NOT apply
  here. That rule hides where a private poet IS. These are public venues a
  public poet chose to recommend -- the whole point is that a reader can find
  them.
  """

  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.GuideComponents

  alias TravelingPoet.Poets
  alias TravelingPoetWeb.GuideState

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Poets.get_public_poet_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That journal doesn't exist or isn't public.")
         |> push_navigate(to: ~p"/")}

      poet ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{poet.id}")
        end

        {:ok,
         socket
         |> assign(:poet, poet)
         |> assign(:selected, nil)
         |> assign(:page_title, "#{poet.name}'s trip guide")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns[:poet] do
      nil -> {:noreply, socket}
      _poet -> {:noreply, GuideState.apply_params(socket, params)}
    end
  end

  @impl true
  def handle_event("set_view", %{"view" => view}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, view: view))}

  def handle_event("set_filter", %{"filter" => filter}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, filter: filter))}

  def handle_event("set_stay", %{"stay" => stay}, socket),
    do: {:noreply, push_patch(socket, to: guide_path(socket, stay: stay))}

  def handle_event("select_place", %{"id" => id}, socket),
    do: {:noreply, GuideState.select_place(socket, id)}

  @impl true
  def handle_info({:guide_geocoded, _poet_id}, socket), do: {:noreply, reload(socket)}
  def handle_info({:journal_published, _id}, socket), do: {:noreply, reload(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload(socket), do: socket |> GuideState.assign_places() |> GuideState.push_map()

  defp guide_path(socket, overrides),
    do: ~p"/p/#{socket.assigns.poet.slug}/guide?#{GuideState.query(socket, overrides)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={assigns[:current_user]}>
      <div class="flex items-center gap-3 mb-6">
        <img
          :if={@poet.avatar_url}
          src={@poet.avatar_url}
          class="w-12 h-12 rounded-full object-cover"
          alt={@poet.name}
        />
        <div>
          <h1 class="text-xl font-semibold">{@poet.name}</h1>
          <p class="text-sm opacity-70">
            a traveling poet
            <span :if={@poet.current_place_name}>· 📍 {@poet.current_place_name}</span>
          </p>
        </div>
        <div class="ml-auto flex gap-1">
          <.link navigate={~p"/p/#{@poet.slug}"} class="btn btn-ghost btn-sm">Journal</.link>
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm">World map</.link>
        </div>
      </div>

      <.guide_header poet={@poet} stay={@stay} view={@view} />
      <.filter_chips filter={@filter} counts={@counts} />
      <.stay_switcher stays={@stays} stay={@stay} />

      <.empty_state :if={@places == []} poet={@poet} />

      <div :if={@places != []}>
        <.map_view
          :if={@view == "map"}
          map_places={@map_places}
          selected={@selected}
          media={@media}
          poet={@poet}
          unmapped={@unmapped}
        />
        <.list_view :if={@view == "list"} places={@places} media={@media} poet={@poet} />
        <.itinerary_view
          :if={@view == "itinerary"}
          days={@days}
          media={@media}
          poet={@poet}
          stay={@stay}
        />
      </div>
    </Layouts.app>
    """
  end
end
