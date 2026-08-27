defmodule TravelingPoetWeb.SettingsLive do
  use TravelingPoetWeb, :live_view

  alias TravelingPoet.{Accounts, Poets, Provisioner}
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Telegram

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    poet = Poets.get_poet_by_user(user.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:user, user)
     |> assign(:poet, poet)
     |> assign(:telegram_configured, Telegram.Client.configured?())
     |> assign(:telegram_link, nil)
     |> assign(:stops, (poet && Poets.list_stops(poet.id)) || [])
     |> assign(:stop_query, "")
     |> assign(:stop_results, [])
     |> assign(:stop_error, nil)}
  end

  @impl true
  def handle_event("save_poet", params, socket) do
    poet = socket.assigns.poet

    settings =
      (poet.settings || %{})
      |> Map.put("stay_duration_days", parse_days(params["stay_duration_days"]))
      |> Map.put("telegram_notify", params["telegram_notify"] == "on")
      |> Map.put("verbosity", parse_verbosity(params["verbosity"]))

    attrs = %{
      personality: params["personality"],
      is_public: params["is_public"] == "on",
      settings: settings
    }

    case Poets.update_poet(poet, attrs) do
      {:ok, updated} ->
        {:noreply, assign(socket, :poet, updated)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not save settings.")}
    end
  end

  @impl true
  def handle_event("switch_mode", %{"mode" => mode}, socket) when mode in ["wander", "scout"] do
    poet = socket.assigns.poet
    pending = Enum.count(socket.assigns.stops, &is_nil(&1.visited_at))

    cond do
      Poet.mode(poet) == mode ->
        {:noreply, socket}

      mode == "scout" and pending == 0 ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Add at least one itinerary stop below before switching to Trip Scout."
         )}

      true ->
        {:ok, updated} =
          Poets.update_poet(poet, %{settings: Map.put(poet.settings || %{}, "mode", mode)})

        # The mission (and its model) is baked into the sprite at provision
        # time — repack in the background; keys/tokens are reused so nothing
        # else is disturbed.
        user = socket.assigns.user

        Task.start(fn ->
          case Provisioner.provision_user(user) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              require Logger
              Logger.error("Mode-switch re-provision failed: #{inspect(reason)}")
          end
        end)

        {:noreply,
         socket
         |> assign(:poet, updated)
         |> put_flash(:info, "Your poet is repacking for the new mission — ready in ~2 minutes.")}
    end
  end

  @impl true
  def handle_event("search_stop", %{"query" => query}, socket) do
    case String.trim(query) do
      "" ->
        {:noreply, socket}

      q ->
        case TravelingPoet.Geocoder.search(q) do
          {:ok, results} ->
            {:noreply,
             socket
             |> assign(:stop_query, q)
             |> assign(:stop_results, results)
             |> assign(:stop_error, if(results == [], do: "No places found."))}

          {:error, reason} ->
            {:noreply, assign(socket, :stop_error, "Search failed: #{reason}")}
        end
    end
  end

  @impl true
  def handle_event("add_stop", %{"idx" => idx}, socket) do
    with result when not is_nil(result) <-
           Enum.at(socket.assigns.stop_results, String.to_integer(idx)),
         {:ok, _} <- Poets.add_stop(socket.assigns.poet.id, result) do
      {:noreply,
       socket
       |> assign(:stops, Poets.list_stops(socket.assigns.poet.id))
       |> assign(:stop_results, [])
       |> assign(:stop_query, "")}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_stop", %{"id" => id}, socket) do
    Poets.remove_stop(socket.assigns.poet.id, String.to_integer(id))
    {:noreply, assign(socket, :stops, Poets.list_stops(socket.assigns.poet.id))}
  end

  @impl true
  def handle_event("telegram_pair_link", _params, socket) do
    case Telegram.Pairing.mint_pair_link(socket.assigns.user) do
      {:ok, link} -> {:noreply, assign(socket, :telegram_link, link)}
      _ -> {:noreply, put_flash(socket, :error, "Could not create a pairing link.")}
    end
  end

  @impl true
  def handle_event("telegram_unpair", _params, socket) do
    case Telegram.Pairing.unpair(socket.assigns.user) do
      {:ok, user} ->
        {:noreply, socket |> assign(:user, user) |> put_flash(:info, "Telegram unpaired.")}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:telegram_paired, _username}, socket) do
    {:noreply,
     socket
     |> assign(:user, Accounts.get_user!(socket.assigns.user.id))
     |> put_flash(:info, "Telegram paired ✓")}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp parse_days(str) do
    case Integer.parse(to_string(str)) do
      {n, _} when n in 1..30 -> n
      _ -> 3
    end
  end

  defp parse_verbosity(v) when v in ["brief", "balanced", "expansive"], do: v
  defp parse_verbosity(_), do: "balanced"

  defp verbosity_options do
    [
      {"brief", "Brief — short postcards, a few lines and a poem"},
      {"balanced", "Balanced — a paragraph or two per section"},
      {"expansive", "Expansive — full travel-journal essays"}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={assigns[:current_user]}>
      <div class="mx-auto max-w-xl py-8">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-semibold">Settings</h1>
          <.link navigate={~p"/journal"} class="btn btn-ghost btn-sm">← Journal</.link>
        </div>

        <div :if={@poet}>
          <p class="text-xs opacity-60 -mt-4 mb-4">Changes save automatically.</p>
          <form phx-change="save_poet" class="space-y-4">
            <label class="block">
              <span class="text-sm font-medium">{@poet.name}'s personality</span>
              <textarea
                name="personality"
                phx-debounce="750"
                class="textarea textarea-bordered w-full mt-1"
              >{@poet.personality}</textarea>
            </label>

            <label class="block">
              <span class="text-sm font-medium">Days to stay in each place</span>
              <input
                type="number"
                name="stay_duration_days"
                min="1"
                max="30"
                value={Map.get(@poet.settings || %{}, "stay_duration_days", 3)}
                phx-debounce="500"
                class="input input-bordered w-24 mt-1"
              />
            </label>

            <label class="block">
              <span class="text-sm font-medium">Journal chattiness</span>
              <select name="verbosity" class="select select-bordered w-full mt-1">
                <option
                  :for={{value, label} <- verbosity_options()}
                  value={value}
                  selected={Map.get(@poet.settings || %{}, "verbosity", "balanced") == value}
                >
                  {label}
                </option>
              </select>
            </label>

            <label class="flex items-center gap-3">
              <input
                type="checkbox"
                name="is_public"
                class="toggle toggle-primary"
                checked={@poet.is_public}
              />
              <span>
                <b>Public journal</b>
                <span class="block text-sm opacity-60">
                  Show {@poet.name} on the world map; anyone can read the journal
                </span>
              </span>
            </label>

            <label class="flex items-center gap-3">
              <input
                type="checkbox"
                name="telegram_notify"
                class="toggle"
                checked={Map.get(@poet.settings || %{}, "telegram_notify", true)}
              />
              <span>Telegram note when a new entry is published</span>
            </label>
          </form>

          <div class="divider"></div>

          <h2 class="font-semibold mb-2">Mission</h2>
          <div class="flex gap-2 mb-3">
            <button
              phx-click="switch_mode"
              phx-value-mode="wander"
              class={["btn btn-sm flex-1", Poet.mode(@poet) == "wander" && "btn-primary"]}
            >
              🧭 Wanderer
            </button>
            <button
              phx-click="switch_mode"
              phx-value-mode="scout"
              class={["btn btn-sm flex-1", Poet.mode(@poet) == "scout" && "btn-primary"]}
            >
              🗺️ Trip Scout
            </button>
          </div>
          <p class="text-xs opacity-60 mb-4">
            Switching missions repacks your poet (~2 minutes). Trip Scouts follow the
            itinerary below, in order, on a more careful model.
          </p>

          <h3 class="text-sm font-medium mb-2">
            Trip itinerary {if Poet.mode(@poet) != "scout", do: "(used in Trip Scout mode)"}
          </h3>
          <form phx-submit="search_stop" class="flex gap-2 mb-2">
            <input
              type="text"
              name="query"
              value={@stop_query}
              class="input input-bordered input-sm flex-1"
              placeholder="Add a place…"
            />
            <button type="submit" class="btn btn-sm">Search</button>
          </form>
          <p :if={@stop_error} class="text-error text-xs mb-2">{@stop_error}</p>
          <div :if={@stop_results != []} class="space-y-1 mb-2">
            <button
              :for={{result, idx} <- Enum.with_index(@stop_results)}
              phx-click="add_stop"
              phx-value-idx={idx}
              class="btn btn-outline btn-xs w-full justify-start text-left normal-case"
            >
              + {result.place_name}
            </button>
          </div>
          <ol :if={@stops != []} class="space-y-1 mb-2">
            <li
              :for={stop <- @stops}
              class="flex items-center gap-2 text-sm p-2 rounded-lg bg-base-200"
            >
              <span>{if stop.visited_at, do: "✓", else: "#{stop.position + 1}."}</span>
              <span class={["flex-1", stop.visited_at && "opacity-50 line-through"]}>
                {stop.place_name}
              </span>
              <button
                :if={is_nil(stop.visited_at)}
                phx-click="remove_stop"
                phx-value-id={stop.id}
                class="btn btn-ghost btn-xs"
              >
                ✕
              </button>
            </li>
          </ol>
          <p :if={@stops == []} class="text-xs opacity-60 mb-2">No stops yet.</p>

          <div class="divider"></div>

          <h2 class="font-semibold mb-2">Telegram</h2>
          <div :if={!@telegram_configured} class="text-sm opacity-60">
            Telegram isn't configured on this server.
          </div>
          <div :if={@telegram_configured}>
            <div :if={@user.telegram_chat_id} class="flex items-center gap-3">
              <span class="text-sm">
                Paired{if @user.telegram_username, do: " as @#{@user.telegram_username}"} ✓
              </span>
              <button phx-click="telegram_unpair" class="btn btn-outline btn-sm">Unpair</button>
            </div>
            <div :if={is_nil(@user.telegram_chat_id)} class="space-y-2">
              <button phx-click="telegram_pair_link" class="btn btn-secondary btn-sm">
                Generate pairing link
              </button>
              <div :if={@telegram_link}>
                <a href={@telegram_link} target="_blank" rel="noopener" class="link break-all">
                  {@telegram_link}
                </a>
              </div>
            </div>
          </div>

          <div class="divider"></div>

          <a href={~p"/auth/logout"} class="btn btn-ghost btn-sm">Sign out</a>
        </div>

        <div :if={is_nil(@poet)}>
          <p class="opacity-70">
            No poet yet — <.link navigate={~p"/onboarding"} class="link">set one up</.link>.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
