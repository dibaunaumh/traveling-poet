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

  alias TravelingPoet.{Accounts, Bookmarks, NearHome, Poets, Topics}
  alias TravelingPoet.NearHome.Away
  alias TravelingPoetWeb.{Bookmarking, GoogleMapsSaving}

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
         asking: NearHome.looking?(user.id),
         journeys: Topics.list_guide_topics(poet.id),
         saved_count: Bookmarks.count(user.id)
       )
       |> Bookmarking.assign_bookmarks()
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

  # Picks landed, or a turn started or ended, here or elsewhere: the
  # reader's place may have moved too (card-78). `asking` follows the turn.
  defp reload(socket, asking) do
    user = Accounts.get_user!(socket.assigns.current_user.id)

    socket =
      socket
      |> assign(:current_user, user)
      |> assign(:asking, asking)
      |> load()

    if connected?(socket),
      do: push_event(socket, "map:update", %{places: socket.assigns.map_places}),
      else: socket
  end

  @impl true
  def handle_event("set_journey", %{"topic" => ""}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/guide")}

  def handle_event("set_journey", %{"topic" => topic}, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/guide?#{[topic: topic, view: "route"]}")}

  # Save and Not for me on a pick (`Bookmarks`, kind "near")
  def handle_event(event, params, socket) when event in ["toggle_bookmark", "toggle_pass"] do
    {:noreply, socket} = Bookmarking.handle_event(event, params, socket)
    {:noreply, assign(socket, :saved_count, Bookmarks.count(socket.assigns.current_user.id))}
  end

  def handle_event("set_saved", _params, socket),
    do: {:noreply, push_navigate(socket, to: ~p"/guide?saved=1")}

  # "Notice when I am away" from here: the same switch as Settings' (card-78)
  def handle_event("away_on", _params, socket) do
    {:ok, user} = Away.set_enabled(socket.assigns.current_user, true)
    {:noreply, socket |> assign(:current_user, user) |> push_event("here:now", %{})}
  end

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
  def handle_info({:near_home, :looking}, socket), do: {:noreply, reload(socket, true)}
  def handle_info({:near_home, _date_or_done}, socket), do: {:noreply, reload(socket, false)}

  def handle_info({:near_home_turn, result}, socket) do
    socket = reload(socket, false)
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
    here = Away.here(assigns.current_user)
    around = around(assigns.picks)

    assigns =
      assigns
      |> assign(:home?, NearHome.home?(assigns.current_user))
      |> assign(:here, here && Away.display_name(here.name, here.lat, here.lng))
      |> assign(:around, around)
      # Away, Near you runs on the "notice when I am away" switch
      |> assign(:on?, assigns.current_user.near_home != false or here != nil)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user} active_tab={:guide}>
      <div class="mb-4">
        <h1 class="text-2xl font-semibold">{dgettext("guide", "Trip guide")}</h1>
        <p :if={@home?} class="text-sm opacity-60 mt-1">
          {dgettext(
            "guide",
            "What is on within %{km} km of %{home} in the coming days, found by %{poet}",
            km: NearHome.radius_km(),
            home: heading_place(@picks, @around, @here, @current_user),
            poet: @poet.name
          )}
        </p>
      </div>

      <div
        :if={@here && @on? && @here != @around}
        id="near-away"
        class="flex flex-wrap items-center gap-x-3 gap-y-2 mb-4 px-3 py-2 rounded-lg bg-base-200 text-sm"
      >
        <.icon name="hero-map-pin" class="size-4 shrink-0 opacity-70" />
        <span class="flex-1 min-w-48">
          {if @asking,
            do:
              dgettext(
                "guide",
                "You are in %{place}. %{poet} is looking for things to do around you. This takes about ten minutes.",
                place: @here,
                poet: @poet.name
              ),
            else: dgettext("guide", "You are in %{place}, away from home.", place: @here)}
        </span>
        <.look_now :if={!@asking} asking={@asking} poet={@poet} />
      </div>

      <div
        :if={@home? and not @current_user.away_aware}
        id="near-away-offer"
        class="flex flex-wrap items-center gap-x-3 gap-y-2 mb-4 text-sm"
      >
        <span class="flex-1 min-w-48 opacity-70">
          {dgettext(
            "guide",
            "Traveling? %{poet} can look around wherever you are, while the app is open.",
            poet: @poet.name
          )}
        </span>
        <button id="near-away-on" type="button" phx-click="away_on" class="btn btn-ghost btn-xs">
          {dgettext("guide", "Notice when I am away")}
        </button>
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
        <.link navigate={~p"/settings#home"} class="btn btn-primary btn-sm">
          {dgettext("guide", "Set your home city")}
        </.link>
      </div>

      <div :if={@home? and not @on?} id="near-off" class="py-10 text-center text-sm space-y-3">
        <p class="opacity-70">{dgettext("guide", "Near you is switched off.")}</p>
        <.link navigate={~p"/settings#home"} class="btn btn-sm">
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
        <.look_now :if={is_nil(@here)} asking={@asking} poet={@poet} />
        <p :if={@asking and is_nil(@here)} id="near-asking-note" class="opacity-70 max-w-md mx-auto">
          {dgettext(
            "guide",
            "This takes about ten minutes: %{poet} reads the local listings and venues' own pages. You can leave; the list lands here, on your journal and as a notification.",
            poet: @poet.name
          )}
        </p>
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
          <.pick_card
            :for={{pick, n} <- Enum.with_index(@picks, 1)}
            pick={pick}
            n={n}
            bookmarks={@bookmarks}
          />
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

  # The place the list is around: the batch's own, else (no list yet) where
  # the poet will look, which is where the reader is when away.
  defp heading_place([_ | _], around, _here, user), do: around || user.home_place_name
  defp heading_place([], _around, here, user), do: here || user.home_place_name

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
