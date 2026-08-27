defmodule TravelingPoetWeb.OnboardingLive do
  use TravelingPoetWeb, :live_view

  alias TravelingPoet.{Accounts, Geocoder, Poets, Provisioner}

  require Logger

  # step list depends on chosen mode (alice-in's conditional-steps lesson:
  # derive one list and use it everywhere)
  defp steps("scout"), do: [:you, :poet, :mode, :itinerary, :visibility, :telegram, :review]
  defp steps(_wander), do: [:you, :poet, :mode, :location, :visibility, :telegram, :review]

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if user.onboarding_completed and Poets.get_poet_by_user(user.id) do
      {:ok, push_navigate(socket, to: ~p"/journal")}
    else
      if connected?(socket) do
        Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")
      end

      {:ok,
       socket
       |> assign(:page_title, "Set up your poet")
       |> assign(:step, :you)
       |> assign(:user_name, user.name || "")
       |> assign(:user_interests, "")
       |> assign(:poet_name, "")
       |> assign(:poet_personality, "")
       |> assign(:verbosity, "balanced")
       |> assign(:mode, "wander")
       |> assign(:stops, [])
       |> assign(:reading_list, Geocoder.reading_list())
       |> assign(:selected_reading, MapSet.new())
       |> assign(:custom_reading, "")
       |> assign(:location, nil)
       |> assign(:location_query, "")
       |> assign(:location_results, [])
       |> assign(:location_error, nil)
       |> assign(:is_public, false)
       |> assign(:telegram_configured, telegram_configured?())
       |> assign(:telegram_link, nil)
       |> assign(:telegram_paired, user.telegram_chat_id != nil)
       |> assign(:provisioning, false)}
    end
  end

  ## Step navigation

  @impl true
  def handle_event("next", params, socket) do
    socket = capture_step(socket, params)
    {:noreply, assign(socket, :step, next_step(socket.assigns.step, socket.assigns.mode))}
  end

  @impl true
  def handle_event("back", _params, socket) do
    {:noreply, assign(socket, :step, prev_step(socket.assigns.step, socket.assigns.mode))}
  end

  ## Step 2: reading picks

  @impl true
  def handle_event("toggle_reading", %{"idx" => idx}, socket) do
    idx = String.to_integer(idx)

    selected =
      if MapSet.member?(socket.assigns.selected_reading, idx),
        do: MapSet.delete(socket.assigns.selected_reading, idx),
        else: MapSet.put(socket.assigns.selected_reading, idx)

    {:noreply, assign(socket, :selected_reading, selected)}
  end

  ## Mode step

  @impl true
  def handle_event("choose_mode", %{"mode" => mode}, socket) when mode in ["wander", "scout"] do
    {:noreply,
     socket
     |> assign(:mode, mode)
     |> assign(:step, next_step(:mode, mode))}
  end

  ## Itinerary step (scout)

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

  ## Step 3: location

  @impl true
  def handle_event("search_location", %{"query" => query}, socket) do
    query = String.trim(query)

    if query == "" do
      {:noreply, socket}
    else
      case Geocoder.search(query) do
        {:ok, results} ->
          # Auto-select the top hit: beta testing showed users type a place,
          # press Search, and expect Continue to work without also clicking a
          # result (they can still click a different one to switch).
          {:noreply,
           socket
           |> assign(:location_query, query)
           |> assign(:location_results, results)
           |> assign(:location, List.first(results) || socket.assigns.location)
           |> assign(
             :location_error,
             if(results == [], do: "No places found — try a broader name.")
           )}

        {:error, reason} ->
          {:noreply, assign(socket, :location_error, "Search failed: #{reason}")}
      end
    end
  end

  @impl true
  def handle_event("pick_location", %{"idx" => idx}, socket) do
    location = Enum.at(socket.assigns.location_results, String.to_integer(idx))
    {:noreply, socket |> assign(:location, location) |> assign(:location_results, [])}
  end

  @impl true
  def handle_event("surprise_location", _params, socket) do
    loc = Geocoder.random_start_location()

    {:noreply,
     assign(socket, :location, %{
       place_name: loc["place_name"],
       lat: loc["lat"],
       lng: loc["lng"],
       country_code: loc["country_code"]
     })}
  end

  ## Step 4: visibility

  @impl true
  def handle_event("set_visibility", %{"public" => public}, socket) do
    {:noreply, assign(socket, :is_public, public == "true")}
  end

  ## Step 5: telegram

  @impl true
  def handle_event("telegram_pair_link", _params, socket) do
    case TravelingPoet.Telegram.Pairing.mint_pair_link(socket.assigns.current_user) do
      {:ok, link} -> {:noreply, assign(socket, :telegram_link, link)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Could not create a pairing link.")}
    end
  end

  ## Step 6: create

  @impl true
  def handle_event("create_poet", _params, socket) do
    user = socket.assigns.current_user

    reading_items =
      socket.assigns.selected_reading
      |> Enum.map(&Enum.at(socket.assigns.reading_list, &1))
      |> Enum.reject(&is_nil/1)
      |> maybe_add_custom_reading(socket.assigns.custom_reading)

    location =
      case socket.assigns.mode do
        "scout" -> List.first(socket.assigns.stops)
        _ -> socket.assigns.location
      end

    attrs = %{
      user_id: user.id,
      name: socket.assigns.poet_name,
      personality: socket.assigns.poet_personality,
      interests: split_interests(socket.assigns.user_interests),
      currently_reading: %{"items" => reading_items},
      is_public: socket.assigns.is_public,
      current_lat: location && location.lat,
      current_lng: location && location.lng,
      current_place_name: location && location.place_name,
      current_country_code: location && location.country_code,
      arrived_at: DateTime.utc_now() |> DateTime.truncate(:second),
      settings: %{
        "stay_duration_days" => 3,
        "mode" => socket.assigns.mode,
        "verbosity" => socket.assigns.verbosity,
        "user_interests" => split_interests(socket.assigns.user_interests)
      }
    }

    with {:ok, name_ok} <- validate_poet_name(socket.assigns.poet_name),
         :ok <- validate_mode_inputs(socket.assigns),
         {:ok, poet} <- Poets.create_poet(%{attrs | name: name_ok}) do
      # Record the starting point as path point zero
      if location, do: Poets.move_to(poet, location)

      if socket.assigns.mode == "scout" do
        Enum.each(socket.assigns.stops, fn stop -> Poets.add_stop(poet.id, stop) end)
      end

      {:ok, _} =
        Accounts.update_user(user, %{
          name: socket.assigns.user_name,
          onboarding_completed: true
        })

      # Provision in the background; JournalLive picks up :sprite_provisioned
      lv_user = Accounts.get_user!(user.id)

      Task.start(fn ->
        case Provisioner.provision_user(lv_user) do
          {:ok, _} -> :ok
          {:error, reason} -> Logger.error("Provisioning failed: #{inspect(reason)}")
        end
      end)

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
  def handle_info({:telegram_paired, username}, socket) do
    {:noreply,
     socket
     |> assign(:telegram_paired, true)
     |> put_flash(:info, "Telegram connected#{if username, do: " as @#{username}"} ✓")}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  ## Helpers

  defp capture_step(socket, params) do
    case socket.assigns.step do
      :you ->
        socket
        |> assign(:user_name, params["name"] || socket.assigns.user_name)
        |> assign(:user_interests, params["interests"] || socket.assigns.user_interests)

      :poet ->
        socket
        |> assign(:poet_name, params["poet_name"] || socket.assigns.poet_name)
        |> assign(:poet_personality, params["personality"] || socket.assigns.poet_personality)
        |> assign(:custom_reading, params["custom_reading"] || socket.assigns.custom_reading)
        |> assign(:verbosity, params["verbosity"] || socket.assigns.verbosity)

      _ ->
        socket
    end
  end

  defp next_step(step, mode) do
    list = steps(mode)
    idx = Enum.find_index(list, &(&1 == step))
    Enum.at(list, min(idx + 1, length(list) - 1))
  end

  defp prev_step(step, mode) do
    list = steps(mode)
    idx = Enum.find_index(list, &(&1 == step))
    Enum.at(list, max(idx - 1, 0))
  end

  defp step_number(step, mode), do: Enum.find_index(steps(mode), &(&1 == step)) + 1
  defp step_count(mode), do: length(steps(mode))

  defp validate_mode_inputs(%{mode: "scout", stops: []}),
    do: {:error, "A Trip Scout needs at least one planned stop — go back and add one."}

  defp validate_mode_inputs(_), do: :ok

  defp validate_poet_name(name) do
    case String.trim(name) do
      "" -> {:error, "Your poet needs a name — go back to step 2."}
      trimmed -> {:ok, trimmed}
    end
  end

  defp split_interests(text) do
    text
    |> String.split(~r/[,\n]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_add_custom_reading(items, custom) do
    case String.trim(custom) do
      "" -> items
      text -> items ++ [%{"title" => text, "author" => ""}]
    end
  end

  defp telegram_configured? do
    Application.get_env(:traveling_poet, :telegram_bot_token) not in [nil, ""]
  end

  ## Render

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={assigns[:current_user]}>
      <div class="mx-auto max-w-xl py-8">
        <div class="mb-6">
          <div class="text-sm opacity-60 mb-1">
            Step {step_number(@step, @mode)} of {step_count(@mode)}
          </div>
          <progress
            class="progress progress-primary w-full"
            value={step_number(@step, @mode)}
            max={step_count(@mode)}
          />
        </div>

        <div :if={@step == :you}>
          <h1 class="text-2xl font-semibold mb-2">About you</h1>
          <p class="opacity-70 mb-4">
            Your poet writes home to you — tell them who's reading.
          </p>
          <form phx-submit="next" class="space-y-4">
            <label class="block">
              <span class="text-sm font-medium">Your name</span>
              <input
                type="text"
                name="name"
                value={@user_name}
                class="input input-bordered w-full mt-1"
                required
              />
            </label>
            <label class="block">
              <span class="text-sm font-medium">
                What would you love postcards about? (comma-separated)
              </span>
              <textarea
                name="interests"
                class="textarea textarea-bordered w-full mt-1"
                placeholder="street food, modernist architecture, jazz, wild coastlines"
              >{@user_interests}</textarea>
            </label>
            <button type="submit" class="btn btn-primary w-full">Continue</button>
          </form>
        </div>

        <div :if={@step == :poet}>
          <h1 class="text-2xl font-semibold mb-2">Your traveling poet</h1>
          <p class="opacity-70 mb-4">Give them a name, a temperament, and a book for the road.</p>
          <form phx-submit="next" class="space-y-4">
            <label class="block">
              <span class="text-sm font-medium">Poet's name</span>
              <input
                type="text"
                name="poet_name"
                value={@poet_name}
                class="input input-bordered w-full mt-1"
                placeholder="Wren, Basho-of-the-Buses, Señora Tinta…"
                required
              />
            </label>
            <label class="block">
              <span class="text-sm font-medium">Personality</span>
              <textarea
                name="personality"
                class="textarea textarea-bordered w-full mt-1"
                placeholder="melancholy but funny; talks to cats; obsessed with bridges"
              >{@poet_personality}</textarea>
            </label>
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
              <div class="mt-2 flex flex-wrap gap-2">
                <button
                  :for={{book, idx} <- Enum.with_index(@reading_list)}
                  type="button"
                  phx-click="toggle_reading"
                  phx-value-idx={idx}
                  class={[
                    "btn btn-xs",
                    if(MapSet.member?(@selected_reading, idx), do: "btn-primary", else: "btn-outline")
                  ]}
                >
                  {book["title"]}
                </button>
              </div>
              <input
                type="text"
                name="custom_reading"
                value={@custom_reading}
                class="input input-bordered input-sm w-full mt-2"
                placeholder="…or any other book (free text)"
              />
            </div>
            <div class="flex gap-2">
              <button type="button" phx-click="back" class="btn btn-ghost">Back</button>
              <button type="submit" class="btn btn-primary flex-1">Continue</button>
            </div>
          </form>
        </div>

        <div :if={@step == :mode}>
          <h1 class="text-2xl font-semibold mb-2">What's the mission?</h1>
          <p class="opacity-70 mb-4">You can switch modes later in settings.</p>
          <div class="space-y-3 mb-6">
            <button
              phx-click="choose_mode"
              phx-value-mode="wander"
              class="w-full text-left p-4 rounded-xl border border-base-300 hover:border-primary"
            >
              <div class="text-lg font-semibold">🧭 Wanderer</div>
              <div class="text-sm opacity-70">
                Let your poet wander the world freely — a new nearby place every few
                days, discoveries you never asked for.
              </div>
            </button>
            <button
              phx-click="choose_mode"
              phx-value-mode="scout"
              class="w-full text-left p-4 rounded-xl border border-base-300 hover:border-primary"
            >
              <div class="text-lg font-semibold">🗺️ Trip Scout</div>
              <div class="text-sm opacity-70">
                Planning a real trip? Your poet pre-visits the places on your route, in
                order, and reports what will interest you when you get there.
              </div>
            </button>
          </div>
          <button phx-click="back" class="btn btn-ghost">Back</button>
        </div>

        <div :if={@step == :itinerary}>
          <h1 class="text-2xl font-semibold mb-2">Where are you planning to go?</h1>
          <p class="opacity-70 mb-4">
            Add the places in the order you'll visit them. Your poet starts scouting at
            the first one.
          </p>
          <form phx-submit="search_location" class="flex gap-2 mb-3">
            <input
              type="text"
              name="query"
              value={@location_query}
              class="input input-bordered flex-1"
              placeholder="Search a city or town…"
            />
            <button type="submit" class="btn">Search</button>
          </form>
          <p :if={@location_error} class="text-error text-sm mb-2">{@location_error}</p>
          <div :if={@location_results != []} class="space-y-1 mb-3">
            <button
              :for={{result, idx} <- Enum.with_index(@location_results)}
              phx-click="add_stop"
              phx-value-idx={idx}
              class="btn btn-outline btn-sm w-full justify-start text-left normal-case"
            >
              + {result.place_name}
            </button>
          </div>
          <ol :if={@stops != []} class="mb-4 space-y-1">
            <li
              :for={{stop, idx} <- Enum.with_index(@stops)}
              class="flex items-center gap-2 text-sm p-2 rounded-lg bg-base-200"
            >
              <span class="font-semibold">{idx + 1}.</span>
              <span class="flex-1">{stop.place_name}</span>
              <button phx-click="remove_stop" phx-value-idx={idx} class="btn btn-ghost btn-xs">
                ✕
              </button>
            </li>
          </ol>
          <div class="flex gap-2">
            <button phx-click="back" class="btn btn-ghost">Back</button>
            <button phx-click="next" class="btn btn-primary flex-1" disabled={@stops == []}>
              Continue
            </button>
          </div>
        </div>

        <div :if={@step == :location}>
          <h1 class="text-2xl font-semibold mb-2">Where do they set out?</h1>
          <form phx-submit="search_location" class="flex gap-2 mb-3">
            <input
              type="text"
              name="query"
              value={@location_query}
              class="input input-bordered flex-1"
              placeholder="Search a city or town…"
            />
            <button type="submit" class="btn">Search</button>
          </form>
          <p :if={@location_error} class="text-error text-sm mb-2">{@location_error}</p>
          <div :if={@location_results != []} class="space-y-1 mb-3">
            <button
              :for={{result, idx} <- Enum.with_index(@location_results)}
              phx-click="pick_location"
              phx-value-idx={idx}
              class="btn btn-outline btn-sm w-full justify-start text-left normal-case"
            >
              {result.place_name}
            </button>
          </div>
          <div class="flex items-center gap-2 mb-4">
            <button phx-click="surprise_location" class="btn btn-secondary btn-sm">
              🎲 Surprise me
            </button>
            <span :if={@location} class="text-sm">
              Starting from: <b>{@location.place_name}</b>
            </span>
          </div>
          <div class="flex gap-2">
            <button phx-click="back" class="btn btn-ghost">Back</button>
            <button phx-click="next" class="btn btn-primary flex-1" disabled={is_nil(@location)}>
              Continue
            </button>
          </div>
        </div>

        <div :if={@step == :visibility}>
          <h1 class="text-2xl font-semibold mb-2">Share the journal?</h1>
          <p class="opacity-70 mb-4">
            A public journal appears on the world map on our landing page — anyone can read it.
            Your chat with the poet is always private, either way.
          </p>
          <div class="space-y-2 mb-6">
            <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer">
              <input
                type="radio"
                name="visibility"
                class="radio radio-primary mt-1"
                checked={!@is_public}
                phx-click="set_visibility"
                phx-value-public="false"
              />
              <span><b>Private</b> — only you can read the journal</span>
            </label>
            <label class="flex items-start gap-3 p-3 rounded-lg border border-base-300 cursor-pointer">
              <input
                type="radio"
                name="visibility"
                class="radio radio-primary mt-1"
                checked={@is_public}
                phx-click="set_visibility"
                phx-value-public="true"
              />
              <span><b>Public</b> — the journal joins the world map for anyone to enjoy</span>
            </label>
          </div>
          <div class="flex gap-2">
            <button phx-click="back" class="btn btn-ghost">Back</button>
            <button phx-click="next" class="btn btn-primary flex-1">Continue</button>
          </div>
        </div>

        <div :if={@step == :telegram}>
          <h1 class="text-2xl font-semibold mb-2">Chat on Telegram too?</h1>
          <p class="opacity-70 mb-4">
            Optional: pair a Telegram chat so your poet can reach you on the road.
          </p>
          <div :if={!@telegram_configured} class="alert mb-4">
            Telegram isn't configured on this server yet — you can skip this step.
          </div>
          <div :if={@telegram_configured and not @telegram_paired} class="mb-4 space-y-3">
            <button phx-click="telegram_pair_link" class="btn btn-secondary">
              Generate pairing link
            </button>
            <div :if={@telegram_link}>
              <a href={@telegram_link} target="_blank" rel="noopener" class="link break-all">
                {@telegram_link}
              </a>
              <p class="text-sm opacity-60 mt-1">
                Open the link, press <b>Start</b> in Telegram, and this page will update.
              </p>
            </div>
          </div>
          <div :if={@telegram_paired} class="alert alert-success mb-4">Telegram paired ✓</div>
          <div class="flex gap-2">
            <button phx-click="back" class="btn btn-ghost">Back</button>
            <button phx-click="next" class="btn btn-primary flex-1">
              {if @telegram_paired, do: "Continue", else: "Skip for now"}
            </button>
          </div>
        </div>

        <div :if={@step == :review}>
          <h1 class="text-2xl font-semibold mb-2">Ready to set out</h1>
          <ul class="space-y-2 mb-6 text-sm">
            <li><b>Poet:</b> {@poet_name}</li>
            <li :if={@poet_personality != ""}><b>Personality:</b> {@poet_personality}</li>
            <li>
              <b>Mission:</b> {if @mode == "scout", do: "Trip Scout", else: "Wanderer"}
            </li>
            <li :if={@mode == "wander"}>
              <b>Starting from:</b> {(@location && @location.place_name) || "—"}
            </li>
            <li :if={@mode == "scout"}>
              <b>Route:</b> {Enum.map_join(@stops, " → ", & &1.place_name)}
            </li>
            <li><b>Journal:</b> {if @is_public, do: "public", else: "private"}</li>
            <li><b>Telegram:</b> {if @telegram_paired, do: "paired", else: "not paired"}</li>
          </ul>
          <div class="flex gap-2">
            <button phx-click="back" class="btn btn-ghost">Back</button>
            <button
              phx-click="create_poet"
              class="btn btn-primary flex-1"
              phx-disable-with="Packing bags…"
            >
              Send them off 🧳
            </button>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
