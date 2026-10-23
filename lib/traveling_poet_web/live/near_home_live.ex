defmodule TravelingPoetWeb.NearHomeLive do
  @moduledoc """
  "Near you" in the trip guide (card-71): what the poet found this week
  within reach of the reader's home, as cards and pins, with when, where and
  how far, and the venues ready to save to Google Maps (dec-012).

  Owner-only, like Saved: the list gives away where the reader lives. A
  LiveView of its own rather than another mode of `GuideLive`, whose state
  (`GuideState`) is all stays, places and topics; the guide's journey
  switcher links across both.
  """

  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.GuideComponents, only: [journey_switcher: 1, google_maps_save: 1]
  import TravelingPoetWeb.NearHomeComponents

  alias TravelingPoet.{Bookmarks, NearHome, Poets, Topics}
  alias TravelingPoetWeb.GoogleMapsSaving

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    poet = user.onboarding_completed && Poets.get_poet_by_user(user.id)

    if poet do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")
      end

      {:ok,
       socket
       |> assign(
         poet: poet,
         page_title: dgettext("guide", "Near you"),
         asking: false,
         journeys: Topics.list_guide_topics(poet.id),
         saved_count: Bookmarks.count(user.id)
       )
       |> load()}
    else
      {:ok, push_navigate(socket, to: ~p"/onboarding")}
    end
  end

  defp load(socket) do
    picks = NearHome.this_week(socket.assigns.current_user.id)

    socket
    |> assign(:picks, picks)
    |> assign(:map_places, map_payload(picks))
    |> assign(:places, Enum.map(picks, &google_place/1))
    |> GoogleMapsSaving.assign_ids()
  end

  defp reload(socket) do
    socket = load(socket)

    if connected?(socket),
      do: push_event(socket, "map:update", %{places: socket.assigns.map_places}),
      else: socket
  end

  @impl true
  def handle_event("set_journey", %{"topic" => ""}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/guide")}

  def handle_event("set_journey", %{"topic" => topic}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/guide?#{[topic: topic, view: "route"]}")}

  def handle_event("set_saved", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/guide?saved=1")}

  # The pins pop up their own name, blurb and link; nothing to open here.
  def handle_event("select_place", _params, socket), do: {:noreply, socket}

  # "Look now": the week's turn on demand, under the same gates and the same
  # one-a-day cap as the one after a daily page.
  def handle_event("look_now", _params, socket) do
    %{current_user: user, poet: poet} = socket.assigns

    if socket.assigns.asking do
      {:noreply, socket}
    else
      case NearHome.request(user, poet, reply_to: self()) do
        {:ok, :started} -> {:noreply, assign(socket, :asking, true)}
        {:error, reason} -> {:noreply, put_flash(socket, :error, refusal(reason, poet))}
      end
    end
  end

  @impl true
  def handle_async(:google_ids, result, socket),
    do: GoogleMapsSaving.handle_async(result, socket)

  @impl true
  def handle_info({:near_home, _date}, socket), do: {:noreply, reload(socket)}

  def handle_info({:near_home_turn, result}, socket) do
    socket = socket |> assign(:asking, false) |> reload()
    poet = socket.assigns.poet

    cond do
      match?({:ok, _}, result) and socket.assigns.picks != [] ->
        {:noreply, socket}

      match?({:ok, _}, result) ->
        {:noreply,
         put_flash(
           socket,
           :info,
           dgettext("guide", "%{poet} found nothing that fits this week.", poet: poet.name)
         )}

      true ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("guide", "%{poet} did not get back. Try again in a while.", poet: poet.name)
         )}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refusal(:no_home, _poet), do: dgettext("guide", "Set your home city in Settings first.")

  defp refusal(:off, _poet),
    do: dgettext("guide", "Near you is switched off. Turn it on in Settings.")

  defp refusal(:credits, poet),
    do: dgettext("guide", "%{poet} is out of credits. Top up in Settings.", poet: poet.name)

  defp refusal(:cap, poet),
    do: dgettext("guide", "%{poet} already looked near you today.", poet: poet.name)

  defp refusal(:busy, poet),
    do:
      dgettext("guide", "%{poet} is in the middle of something. Try again in a few minutes.",
        poet: poet.name
      )

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:home?, NearHome.home?(assigns.current_user))
      |> assign(:on?, assigns.current_user.near_home != false)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_tab={:guide}>
      <div class="mb-4">
        <h1 class="text-2xl font-semibold">{dgettext("guide", "Trip guide")}</h1>
        <p :if={@home?} class="text-sm opacity-60 mt-1">
          {dgettext(
            "guide",
            "What is on within %{km} km of %{home} in the coming days, found by %{poet}",
            km: NearHome.radius_km(),
            home: @current_user.home_place_name,
            poet: @poet.name
          )}
        </p>
      </div>

      <.journey_switcher
        journeys={@journeys}
        saved_count={@saved_count}
        near={:active}
      />

      <div :if={not @home?} id="near-no-home" class="py-10 text-center text-sm space-y-3">
        <p class="opacity-70">
          {dgettext(
            "guide",
            "Tell %{poet} where you live, and once a week it looks for events, exhibitions and outings near you that fit what you like.",
            poet: @poet.name
          )}
        </p>
        <.link navigate={~p"/settings#trips"} class="btn btn-primary btn-sm">
          {dgettext("guide", "Set your home city")}
        </.link>
      </div>

      <div :if={@home? and not @on?} id="near-off" class="py-10 text-center text-sm space-y-3">
        <p class="opacity-70">{dgettext("guide", "Near you is switched off.")}</p>
        <.link navigate={~p"/settings#trips"} class="btn btn-sm">
          {dgettext("guide", "Turn it on in Settings")}
        </.link>
      </div>

      <div
        :if={@home? and @on? and @picks == []}
        id="near-empty"
        class="py-10 text-center text-sm space-y-3"
      >
        <p class="opacity-70">
          {dgettext(
            "guide",
            "%{poet} looks near you once a week, after a day's page. Nothing for this week yet.",
            poet: @poet.name
          )}
        </p>
        <.look_now asking={@asking} poet={@poet} />
      </div>

      <div :if={@home? and @on? and @picks != []} id="near-picks">
        <.google_maps_save
          id="near-google-maps"
          places={@places}
          ids={@google_ids}
          pending={@google_pending}
        />
        <div
          :if={@map_places != []}
          id="guide-map"
          phx-hook="PoetMap"
          phx-update="ignore"
          data-places={Jason.encode!(@map_places)}
          class="h-[320px] rounded-2xl overflow-hidden border border-base-300 z-0 mb-5"
          dir="ltr"
        >
        </div>
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          <.pick_card :for={{pick, n} <- Enum.with_index(@picks, 1)} pick={pick} n={n} />
        </div>
        <p class="text-xs opacity-60 mt-6">
          {dgettext(
            "guide",
            "A new list every week. Check the details page before you go: times and tickets change."
          )}
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :asking, :boolean, required: true
  attr :poet, :map, required: true

  defp look_now(assigns) do
    ~H"""
    <button
      id="near-look-now"
      type="button"
      phx-click="look_now"
      disabled={@asking}
      class="btn btn-outline btn-sm gap-1"
    >
      <.icon
        name={if @asking, do: "hero-arrow-path", else: "hero-sparkles"}
        class={["size-4", @asking && "motion-safe:animate-spin"]}
      />
      {if @asking,
        do: dgettext("guide", "%{poet} is looking…", poet: @poet.name),
        else: dgettext("guide", "Ask %{poet} to look now", poet: @poet.name)}
    </button>
    """
  end
end
