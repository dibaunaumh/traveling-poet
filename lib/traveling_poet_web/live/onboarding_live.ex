defmodule TravelingPoetWeb.OnboardingLive do
  @moduledoc """
  Three-step setup that can be finished without typing: every screen arrives
  pre-filled (a random poet, a random starting city, Wanderer mission) and
  Continue is always enabled on the default path. Anything picked here can be
  changed later in Settings, and each step change is recorded in
  `users.onboarding_step` so drop-off is visible.
  """
  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.PoetComponents

  alias TravelingPoet.{Accounts, Geocoder, Poets, Provisioner}
  alias TravelingPoet.Poets.Presets

  require Logger

  # The scout itinerary lives inside :journey, so the list is the same for
  # both missions.
  @steps [:poet, :journey, :send_off]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if user.onboarding_completed and Poets.get_poet_by_user(user.id) do
      {:ok, push_navigate(socket, to: ~p"/journal")}
    else
      # The static render and the connected mount are different processes;
      # seeding per user keeps the pre-picked name/city identical across the
      # two (no visible flicker on connect) and makes tests deterministic.
      :rand.seed(:exsss, {user.id, user.id * 7 + 1, user.id * 13 + 5})

      reading_list = Geocoder.reading_list()

      socket =
        socket
        |> assign(:page_title, "Set up your poet")
        |> assign(:step, :poet)
        |> assign(:user_name, user.name || "")
        |> assign(:poet_name, Presets.random_name())
        |> assign(:personalities, Presets.personalities())
        |> assign(:personality_idx, Presets.random_personality_index())
        |> assign(:personality_custom, "")
        |> assign(:personality_mode, :preset)
        |> assign(:verbosity, "balanced")
        |> assign(:more_open, false)
        |> assign(:reading_list, reading_list)
        |> assign(:selected_reading, MapSet.new([Enum.random(0..(length(reading_list) - 1))]))
        |> assign(:custom_reading, "")
        |> assign(:mode, "wander")
        |> assign(:stops, [])
        |> assign(:location, start_location(Geocoder.random_start_location()))
        |> assign(:location_query, "")
        |> assign(:location_results, [])
        |> assign(:location_error, nil)
        |> assign(:show_location_search, false)
        |> assign(:interest_options, Presets.interests())
        |> assign(:selected_interests, MapSet.new())
        |> assign(:custom_interests, "")
        |> assign(:is_public, false)

      socket = if connected?(socket), do: track_step(socket, :poet), else: socket

      {:ok, socket}
    end
  end

  # `?place=Lisbon` comes from the home page's destination box. Geocode it once
  # on the connected mount (the dead render keeps the pre-picked city for a
  # moment); if nothing matches, keep the default and open the search box
  # with the visitor's words in it, so nothing they typed is lost.
  @impl true
  def handle_params(%{"place" => place}, _uri, socket) when is_binary(place) do
    place = String.trim(place)

    if place == "" or not connected?(socket) do
      {:noreply, socket}
    else
      {:noreply, adopt_requested_place(socket, place)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp adopt_requested_place(socket, place) do
    case Geocoder.Limiter.search(place) do
      {:ok, [top | _]} ->
        socket
        |> assign(:location, top)
        |> assign(:location_query, place)
        |> assign(:show_location_search, false)

      {:ok, []} ->
        socket
        |> assign(:location_query, place)
        |> assign(:show_location_search, true)
        |> assign(
          :location_error,
          "Couldn’t find “#{place}” — try another spelling or pick a nearby city."
        )

      {:error, _reason} ->
        socket
        |> assign(:location_query, place)
        |> assign(:show_location_search, true)
        |> assign(
          :location_error,
          "Couldn’t look up “#{place}” right now — search again or pick a city."
        )
    end
  end

  ## Step navigation

  # Keep the server's copy of the step's inputs current on every keystroke.
  # Without this the answers live only in the browser until "Continue", and
  # any re-render in between — picking a chip, a flash landing — repaints the
  # fields from assigns that are still empty, silently wiping what was typed.
  @impl true
  def handle_event("capture", params, socket) do
    {:noreply, capture_step(socket, params)}
  end

  @impl true
  def handle_event("next", params, socket) do
    socket = capture_step(socket, params)

    case socket.assigns.step do
      :poet ->
        case validate_poet_name(socket.assigns.poet_name) do
          {:ok, _} -> {:noreply, go_to(socket, next_step(:poet))}
          {:error, msg} -> {:noreply, put_flash(socket, :error, msg)}
        end

      step ->
        {:noreply, go_to(socket, next_step(step))}
    end
  end

  @impl true
  def handle_event("back", _params, socket) do
    {:noreply, go_to(socket, prev_step(socket.assigns.step))}
  end

  ## Step 1: the poet

  @impl true
  def handle_event("shuffle_name", _params, socket) do
    {:noreply, assign(socket, :poet_name, Presets.random_name(socket.assigns.poet_name))}
  end

  @impl true
  def handle_event("pick_personality", %{"idx" => idx}, socket) do
    {:noreply,
     socket
     |> assign(:personality_idx, String.to_integer(idx))
     |> assign(:personality_mode, :preset)}
  end

  @impl true
  def handle_event("custom_personality", _params, socket) do
    {:noreply, assign(socket, :personality_mode, :custom)}
  end

  @impl true
  def handle_event("toggle_more", _params, socket) do
    {:noreply, assign(socket, :more_open, !socket.assigns.more_open)}
  end

  @impl true
  def handle_event("toggle_reading", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)

    selected =
      if MapSet.member?(socket.assigns.selected_reading, idx),
        do: MapSet.delete(socket.assigns.selected_reading, idx),
        else: MapSet.put(socket.assigns.selected_reading, idx)

    {:noreply, assign(socket, :selected_reading, selected)}
  end

  ## Step 2: the journey

  @impl true
  def handle_event("choose_mode", %{"mode" => mode}, socket) when mode in ["wander", "scout"] do
    {:noreply,
     socket
     |> assign(:mode, mode)
     |> assign(:location_results, [])
     |> assign(:location_error, nil)}
  end

  @impl true
  def handle_event("toggle_location_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_location_search, !socket.assigns.show_location_search)
     |> assign(:location_results, [])
     |> assign(:location_error, nil)}
  end

  @impl true
  def handle_event("search_location", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, socket}
    else
      case TravelingPoet.Geocoder.Limiter.search(query) do
        {:ok, results} ->
          {:noreply,
           socket
           |> assign(:location_query, query)
           |> assign(:location_results, results)
           |> assign(
             :location_error,
             if(results == [], do: "No places found — try a broader name.")
           )
           |> maybe_autoselect(results)}

        {:error, reason} ->
          {:noreply, assign(socket, :location_error, "Search failed: #{reason}")}
      end
    end
  end

  @impl true
  def handle_event("pick_location", %{"idx" => idx}, socket) do
    case Enum.at(socket.assigns.location_results, String.to_integer(idx)) do
      nil ->
        {:noreply, socket}

      location ->
        {:noreply,
         socket
         |> assign(:location, location)
         |> assign(:location_results, [])
         |> assign(:show_location_search, false)}
    end
  end

  @impl true
  def handle_event("surprise_location", _params, socket) do
    current = socket.assigns.location && socket.assigns.location.place_name

    loc =
      Stream.repeatedly(&Geocoder.random_start_location/0)
      |> Enum.find(&(&1["place_name"] != current))

    {:noreply,
     socket
     |> assign(:location, start_location(loc))
     |> assign(:location_results, [])
     |> assign(:show_location_search, false)}
  end

  @impl true
  def handle_event("add_stop", %{"idx" => idx}, socket) do
    case Enum.at(socket.assigns.location_results, String.to_integer(idx)) do
      nil ->
        {:noreply, socket}

      result ->
        {:noreply,
         socket
         |> assign(:stops, socket.assigns.stops ++ [result])
         |> assign(:location_results, [])
         |> assign(:location_query, "")}
    end
  end

  @impl true
  def handle_event("remove_stop", %{"idx" => idx}, socket) do
    {:noreply,
     assign(socket, :stops, List.delete_at(socket.assigns.stops, String.to_integer(idx)))}
  end

  @impl true
  def handle_event("toggle_interest", %{"label" => label}, socket) do
    selected =
      if MapSet.member?(socket.assigns.selected_interests, label),
        do: MapSet.delete(socket.assigns.selected_interests, label),
        else: MapSet.put(socket.assigns.selected_interests, label)

    {:noreply, assign(socket, :selected_interests, selected)}
  end

  ## Step 3: send them off

  @impl true
  def handle_event("create_poet", params, socket) do
    socket = capture_step(socket, params)
    user = socket.assigns.current_user
    assigns = socket.assigns

    reading_items =
      assigns.selected_reading
      |> Enum.sort()
      |> Enum.map(&Enum.at(assigns.reading_list, &1))
      |> Enum.reject(&is_nil/1)
      |> maybe_add_custom_reading(assigns.custom_reading)

    location =
      case assigns.mode do
        "scout" -> List.first(assigns.stops)
        _ -> assigns.location
      end

    interests = effective_interests(assigns)

    attrs = %{
      user_id: user.id,
      name: assigns.poet_name,
      personality: effective_personality(assigns),
      interests: interests,
      currently_reading: %{"items" => reading_items},
      is_public: assigns.is_public,
      current_lat: location && location.lat,
      current_lng: location && location.lng,
      current_place_name: location && location.place_name,
      current_country_code: location && location.country_code,
      arrived_at: DateTime.utc_now() |> DateTime.truncate(:second),
      settings: %{
        "stay_duration_days" => 3,
        "mode" => assigns.mode,
        "verbosity" => assigns.verbosity,
        "user_interests" => interests
      }
    }

    with {:ok, name_ok} <- validate_poet_name(assigns.poet_name),
         :ok <- validate_mode_inputs(assigns),
         {:ok, poet} <- Poets.create_poet(%{attrs | name: name_ok}) do
      # Record the starting point as path point zero
      if location, do: Poets.move_to(poet, location)

      # The first stop is where the poet starts: visited on arrival.
      if assigns.mode == "scout", do: Poets.start_itinerary(poet, assigns.stops)

      user_name =
        case String.trim(assigns.user_name) do
          "" -> user.name
          trimmed -> trimmed
        end

      {:ok, updated_user} =
        Accounts.update_user(user, %{
          name: user_name,
          onboarding_completed: true,
          onboarding_step: "done"
        })

      # Provision in the background; JournalLive picks up :sprite_provisioned
      Provisioner.provision_in_background(updated_user)

      {:noreply,
       socket
       |> put_flash(:info, "#{poet.name} is packing their bags!")
       |> push_navigate(to: ~p"/journal")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         put_flash(socket, :error, "Could not create your poet: #{inspect(changeset.errors)}")}

      {:error, msg} when is_binary(msg) ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  defp capture_step(socket, params) do
    case socket.assigns.step do
      :poet ->
        socket
        |> assign(:poet_name, Map.get(params, "poet_name", socket.assigns.poet_name))
        |> assign(
          :personality_custom,
          Map.get(params, "personality_custom", socket.assigns.personality_custom)
        )
        |> assign(
          :custom_reading,
          Map.get(params, "custom_reading", socket.assigns.custom_reading)
        )
        |> assign(:verbosity, parse_verbosity(params["verbosity"], socket.assigns.verbosity))

      :journey ->
        assign(
          socket,
          :custom_interests,
          Map.get(params, "custom_interests", socket.assigns.custom_interests)
        )

      :send_off ->
        # A checkbox is absent from the params when unchecked, so only read it
        # when this form actually sent the change (it always carries "name").
        socket
        |> assign(:user_name, Map.get(params, "name", socket.assigns.user_name))
        |> then(fn s ->
          if Map.has_key?(params, "name"),
            do: assign(s, :is_public, params["is_public"] == "on"),
            else: s
        end)
    end
  end

  # Wander mode auto-selects the top hit: beta testing showed people type a
  # place, press Search, and expect Continue to work without also clicking a
  # result (they can still click a different one to switch). Scout mode
  # adds stops explicitly, so it only lists.
  defp maybe_autoselect(%{assigns: %{mode: "wander"}} = socket, [top | _]),
    do: assign(socket, :location, top)

  defp maybe_autoselect(socket, _results), do: socket

  defp parse_verbosity(v, _default) when v in ["brief", "balanced", "expansive"], do: v
  defp parse_verbosity(_, default), do: default

  defp go_to(socket, step) do
    socket
    |> assign(:step, step)
    |> track_step(step)
  end

  # Funnel data: where do people stop? Best effort — a failed write must never
  # block the wizard.
  defp track_step(socket, step) do
    case Accounts.update_user(socket.assigns.current_user, %{
           onboarding_step: Atom.to_string(step)
         }) do
      {:ok, user} -> assign(socket, :current_user, user)
      {:error, _} -> socket
    end
  end

  defp next_step(step) do
    idx = Enum.find_index(@steps, &(&1 == step))
    Enum.at(@steps, min(idx + 1, length(@steps) - 1))
  end

  defp prev_step(step) do
    idx = Enum.find_index(@steps, &(&1 == step))
    Enum.at(@steps, max(idx - 1, 0))
  end

  defp step_number(step), do: Enum.find_index(@steps, &(&1 == step)) + 1
  defp step_count, do: length(@steps)

  defp start_location(loc) do
    %{
      place_name: loc["place_name"],
      lat: loc["lat"],
      lng: loc["lng"],
      country_code: loc["country_code"]
    }
  end

  defp effective_personality(%{personality_mode: :custom, personality_custom: custom}),
    do: String.trim(custom)

  defp effective_personality(%{personality_idx: idx}) do
    case Presets.personality_at(idx) do
      %{"text" => text} -> text
      _ -> ""
    end
  end

  defp personality_summary(%{personality_mode: :custom} = assigns),
    do: effective_personality(assigns)

  defp personality_summary(%{personality_idx: idx}) do
    case Presets.personality_at(idx) do
      %{"label" => label} -> label
      _ -> ""
    end
  end

  defp effective_interests(assigns) do
    (Enum.to_list(assigns.selected_interests) ++ Presets.split_interests(assigns.custom_interests))
    |> Enum.uniq()
  end

  defp validate_mode_inputs(%{mode: "scout", stops: []}),
    do: {:error, "A Trip Scout needs at least one planned stop — go back and add one."}

  defp validate_mode_inputs(_), do: :ok

  defp validate_poet_name(name) do
    case String.trim(name) do
      "" -> {:error, "Your poet needs a name — type one or press Shuffle."}
      trimmed -> {:ok, trimmed}
    end
  end

  defp maybe_add_custom_reading(items, custom) do
    case String.trim(custom) do
      "" -> items
      text -> items ++ [%{"title" => text, "author" => ""}]
    end
  end

  defp selected_titles(assigns) do
    assigns.selected_reading
    |> Enum.sort()
    |> Enum.map(&Enum.at(assigns.reading_list, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1["title"])
    |> Kernel.++(
      if(String.trim(assigns.custom_reading) == "", do: [], else: [assigns.custom_reading])
    )
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={assigns[:current_user]}
      credits_low={assigns[:credits_low]}
    >
      <div class="mx-auto max-w-xl py-8">
        <div class="mb-6">
          <div class="text-sm opacity-60 mb-1">
            Step {step_number(@step)} of {step_count()}
          </div>
          <progress
            class="progress progress-primary w-full"
            value={step_number(@step)}
            max={step_count()}
          />
        </div>

        <div :if={@step == :poet}>
          <h1 class="text-2xl font-semibold mb-2">Meet your poet</h1>
          <p class="opacity-70 mb-4">
            We picked one for you — shuffle or tweak anything. You can change all of
            this later in Settings.
          </p>
          <form id="onboarding-poet" phx-submit="next" phx-change="capture" class="space-y-4">
            <label class="block">
              <span class="text-sm font-medium">Poet's name</span>
              <div class="flex gap-2 mt-1">
                <input
                  type="text"
                  name="poet_name"
                  value={@poet_name}
                  class="input input-bordered flex-1"
                  placeholder="Wren, Basho-of-the-Buses, Señora Tinta…"
                />
                <button
                  type="button"
                  id="shuffle-name"
                  phx-click="shuffle_name"
                  class="btn btn-secondary"
                  title="Pick another name"
                >
                  🎲 Shuffle
                </button>
              </div>
            </label>

            <div>
              <span class="text-sm font-medium">Personality</span>
              <div class="mt-2">
                <.personality_chips
                  personalities={@personalities}
                  selected_idx={@personality_idx}
                  custom={@personality_mode == :custom}
                />
              </div>
              <p
                :if={@personality_mode == :preset}
                id="personality-preview"
                class="text-sm opacity-60 mt-2 italic"
              >
                {effective_personality(assigns)}
              </p>
              <textarea
                :if={@personality_mode == :custom}
                name="personality_custom"
                class="textarea textarea-bordered w-full mt-2"
                placeholder="melancholy but funny; talks to cats; obsessed with bridges"
              >{@personality_custom}</textarea>
            </div>

            <button
              type="button"
              id="toggle-more"
              phx-click="toggle_more"
              class="btn btn-ghost btn-sm px-0"
            >
              {if @more_open, do: "▾", else: "▸"} More options
              <span class="opacity-50 font-normal">— chattiness, books for the road</span>
            </button>

            <div :if={@more_open} id="more-options" class="space-y-4 pl-1">
              <div>
                <span class="text-sm font-medium">How chatty should the journal be?</span>
                <div class="mt-2 space-y-1">
                  <label class="flex items-center gap-2 text-sm cursor-pointer">
                    <input
                      type="radio"
                      name="verbosity"
                      value="brief"
                      class="radio radio-sm"
                      checked={@verbosity == "brief"}
                    />
                    <span><b>Brief</b> — short postcards, a few lines and a poem</span>
                  </label>
                  <label class="flex items-center gap-2 text-sm cursor-pointer">
                    <input
                      type="radio"
                      name="verbosity"
                      value="balanced"
                      class="radio radio-sm"
                      checked={@verbosity == "balanced"}
                    />
                    <span><b>Balanced</b> — a solid paragraph or two per section</span>
                  </label>
                  <label class="flex items-center gap-2 text-sm cursor-pointer">
                    <input
                      type="radio"
                      name="verbosity"
                      value="expansive"
                      class="radio radio-sm"
                      checked={@verbosity == "expansive"}
                    />
                    <span><b>Expansive</b> — full travel-journal essays</span>
                  </label>
                </div>
              </div>
              <div>
                <span class="text-sm font-medium">Currently reading (pick any)</span>
                <div class="mt-2">
                  <.book_chips books={@reading_list} selected={@selected_reading} />
                </div>
                <input
                  type="text"
                  name="custom_reading"
                  value={@custom_reading}
                  class="input input-bordered input-sm w-full mt-2"
                  placeholder="…or any other book (free text)"
                />
              </div>
            </div>

            <button type="submit" class="btn btn-primary w-full">Continue</button>
          </form>
        </div>

        <div :if={@step == :journey}>
          <h1 class="text-2xl font-semibold mb-2">Where are they headed?</h1>
          <p class="opacity-70 mb-4">
            A wanderer with a random starting city is ready to go — or plan a real trip.
          </p>
          <div class="space-y-3 mb-4">
            <button
              type="button"
              id="mode-wander"
              phx-click="choose_mode"
              phx-value-mode="wander"
              class={[
                "w-full text-left p-4 rounded-xl border-2",
                if(@mode == "wander", do: "border-primary bg-base-200", else: "border-base-300")
              ]}
            >
              <div class="text-lg font-semibold">
                {if @mode == "wander", do: "🔘", else: "⚪"} 🧭 Wanderer
              </div>
              <div class="text-sm opacity-70">
                Let your poet wander the world freely — a new nearby place every few
                days, discoveries you never asked for.
              </div>
            </button>
            <button
              type="button"
              id="mode-scout"
              phx-click="choose_mode"
              phx-value-mode="scout"
              class={[
                "w-full text-left p-4 rounded-xl border-2",
                if(@mode == "scout", do: "border-primary bg-base-200", else: "border-base-300")
              ]}
            >
              <div class="text-lg font-semibold">
                {if @mode == "scout", do: "🔘", else: "⚪"} 🗺️ Trip Scout
              </div>
              <div class="text-sm opacity-70">
                Planning a real trip? Your poet pre-visits the places on your route, in
                order, and reports what will interest you when you get there.
              </div>
            </button>
          </div>

          <div :if={@mode == "wander"} class="mb-5">
            <div class="flex flex-wrap items-center gap-2 p-3 rounded-lg bg-base-200">
              <span id="start-location" class="text-sm">
                Setting out from <b>{@location && @location.place_name}</b>
              </span>
              <button
                type="button"
                id="surprise-location"
                phx-click="surprise_location"
                class="btn btn-secondary btn-xs"
              >
                🎲 Another
              </button>
              <button
                type="button"
                id="toggle-location-search"
                phx-click="toggle_location_search"
                class="btn btn-ghost btn-xs"
              >
                {if @show_location_search, do: "Never mind", else: "Choose a city"}
              </button>
            </div>
            <div :if={@show_location_search} class="mt-3">
              <form phx-submit="search_location" class="flex gap-2 mb-2">
                <input
                  type="text"
                  name="query"
                  value={@location_query}
                  class="input input-bordered input-sm flex-1"
                  placeholder="Search a city or town…"
                />
                <button type="submit" class="btn btn-sm">Search</button>
              </form>
              <p :if={@location_error} class="text-error text-sm mb-2">{@location_error}</p>
              <div :if={@location_results != []} class="space-y-1">
                <button
                  :for={{result, idx} <- Enum.with_index(@location_results)}
                  type="button"
                  phx-click="pick_location"
                  phx-value-idx={idx}
                  class="btn btn-outline btn-sm w-full justify-start text-left normal-case"
                >
                  {result.place_name}
                </button>
              </div>
            </div>
          </div>

          <div :if={@mode == "scout"} class="mb-5">
            <p class="text-sm opacity-70 mb-2">
              Add the places in the order you'll visit them. Your poet starts scouting at
              the first one.
            </p>
            <form phx-submit="search_location" class="flex gap-2 mb-2">
              <input
                type="text"
                name="query"
                value={@location_query}
                class="input input-bordered input-sm flex-1"
                placeholder="Search a city or town…"
              />
              <button type="submit" class="btn btn-sm">Search</button>
            </form>
            <p :if={@location_error} class="text-error text-sm mb-2">{@location_error}</p>
            <div :if={@location_results != []} class="space-y-1 mb-3">
              <button
                :for={{result, idx} <- Enum.with_index(@location_results)}
                type="button"
                phx-click="add_stop"
                phx-value-idx={idx}
                class="btn btn-outline btn-sm w-full justify-start text-left normal-case"
              >
                + {result.place_name}
              </button>
            </div>
            <ol :if={@stops != []} class="space-y-1">
              <li
                :for={{stop, idx} <- Enum.with_index(@stops)}
                class="flex items-center gap-2 text-sm p-2 rounded-lg bg-base-200"
              >
                <span class="font-semibold">{idx + 1}.</span>
                <span class="flex-1">{stop.place_name}</span>
                <button
                  type="button"
                  phx-click="remove_stop"
                  phx-value-idx={idx}
                  class="btn btn-ghost btn-xs"
                >
                  ✕
                </button>
              </li>
            </ol>
          </div>

          <div class="mb-6">
            <span class="text-sm font-medium">
              What would you love postcards about? <span class="opacity-50">(optional)</span>
            </span>
            <div class="mt-2">
              <.interest_chips interests={@interest_options} selected={@selected_interests} />
            </div>
            <form id="onboarding-interests" phx-change="capture" phx-submit="next">
              <input
                type="text"
                name="custom_interests"
                value={@custom_interests}
                class="input input-bordered input-sm w-full mt-2"
                placeholder="…or anything else, comma-separated"
              />
            </form>
          </div>

          <div class="flex gap-2">
            <button type="button" phx-click="back" class="btn btn-ghost">Back</button>
            <button
              type="button"
              id="journey-continue"
              phx-click="next"
              class="btn btn-primary flex-1"
              disabled={@mode == "scout" and @stops == []}
            >
              Continue
            </button>
          </div>
        </div>

        <div :if={@step == :send_off}>
          <h1 class="text-2xl font-semibold mb-2">Ready to set out</h1>
          <ul class="space-y-2 mb-6 text-sm">
            <li><b>Poet:</b> {@poet_name}</li>
            <li :if={personality_summary(assigns) != ""}>
              <b>Personality:</b> {personality_summary(assigns)}
            </li>
            <li>
              <b>Mission:</b> {if @mode == "scout", do: "Trip Scout", else: "Wanderer"}
            </li>
            <li :if={@mode == "wander"}>
              <b>Starting from:</b> {(@location && @location.place_name) || "—"}
            </li>
            <li :if={@mode == "scout"}>
              <b>Route:</b> {Enum.map_join(@stops, " → ", & &1.place_name)}
            </li>
            <li :if={selected_titles(assigns) != []}>
              <b>Reading:</b> {Enum.join(selected_titles(assigns), ", ")}
            </li>
            <li :if={effective_interests(assigns) != []}>
              <b>Postcards about:</b> {Enum.join(effective_interests(assigns), ", ")}
            </li>
          </ul>

          <form
            id="onboarding-send-off"
            phx-change="capture"
            phx-submit="create_poet"
            class="space-y-4"
          >
            <label class="block">
              <span class="text-sm font-medium">Postcards addressed to</span>
              <input
                type="text"
                name="name"
                value={@user_name}
                class="input input-bordered w-full mt-1"
                placeholder="Your name"
              />
            </label>

            <label class="flex items-start gap-3 cursor-pointer">
              <input
                type="checkbox"
                name="is_public"
                class="toggle toggle-primary mt-1"
                checked={@is_public}
              />
              <span>
                <b>Public journal</b>
                <span class="block text-sm opacity-60">
                  Join the world map on our landing page so anyone can read along.
                  Your chat with the poet stays private either way.
                </span>
              </span>
            </label>

            <p class="text-xs opacity-60">
              You can pair Telegram, rename your poet, and change any of this later in
              Settings.
            </p>

            <div class="flex gap-2">
              <button type="button" phx-click="back" class="btn btn-ghost">Back</button>
              <button
                type="submit"
                id="send-them-off"
                class="btn btn-primary flex-1"
                phx-disable-with="Packing bags…"
              >
                Send them off 🧳
              </button>
            </div>
          </form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
