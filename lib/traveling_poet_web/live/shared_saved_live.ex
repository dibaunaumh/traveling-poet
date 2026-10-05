defmodule TravelingPoetWeb.SharedSavedLive do
  @moduledoc """
  A reader's Saved list shared with friends, at `/shared/:token` (card-93).

  Read-only and needs no account: the friends planning a trip together see
  the same places, the same Plan my days, and can take them into Google
  Maps. The owner chose to share, so the places show as the owner sees them
  (`Bookmarks.places/1`), including their own private poet's; stopping
  sharing kills the link. No drawings here: MediaController serves a
  private poet's media only to its owner.
  """

  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.GuideComponents

  alias TravelingPoet.Bookmarks
  alias TravelingPoet.Guide.DayPlan

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    case Bookmarks.shared_by(token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That shared list no longer exists.")
         |> push_navigate(to: ~p"/")}

      owner ->
        saved = Bookmarks.list(owner.id)
        places = for %{item: %TravelingPoet.Guide.Place{} = p} <- saved, do: p
        poets = for %{poet: %{} = poet} <- saved, into: %{}, do: {poet.id, poet}
        who = first_name(owner)

        {:ok,
         socket
         |> assign(token: token, who: who, places: places, poets: poets, plan_days: 3)
         |> assign(:page_title, "#{who}'s saved places")
         |> assign_plan()}
    end
  end

  @impl true
  def handle_event("plan_days", %{"days" => days}, socket) do
    days =
      case Integer.parse(to_string(days)) do
        {n, _} -> n |> max(1) |> min(7)
        :error -> 3
      end

    {:noreply, socket |> assign(:plan_days, days) |> assign_plan()}
  end

  defp assign_plan(socket),
    do: assign(socket, :day_plan, DayPlan.plan(socket.assigns.places, socket.assigns.plan_days))

  defp first_name(%{name: name}) when is_binary(name) and name != "",
    do: name |> String.split() |> hd()

  defp first_name(_), do: "A friend"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <header class="mb-4">
        <h1 class="text-2xl font-semibold">{@who}'s saved places</h1>
        <p class="text-sm opacity-70">
          Shared from Traveling <em>Poet</em>, where an AI poet travels ahead and writes about the places worth going.
        </p>
      </header>

      <p :if={@places == []} id="shared-empty" class="text-sm opacity-60 py-10 text-center">
        Nothing saved here yet.
      </p>

      <div :if={@places != []}>
        <.maps_export id="shared-to-maps" kml_url={~p"/shared/#{@token}/places.kml"} />
        <.day_plan :if={@day_plan != []} plan={@day_plan} days={@plan_days} />
        <div id="shared-places" class="mt-6 grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <.place_card
            :for={place <- @places}
            place={place}
            poet={@poets[place.poet_id] || %{name: "the poet"}}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
