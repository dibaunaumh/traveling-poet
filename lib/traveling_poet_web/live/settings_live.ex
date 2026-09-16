defmodule TravelingPoetWeb.SettingsLive do
  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.PushNotifications, only: [assign_push: 1, push_settings: 1]
  import TravelingPoetWeb.TelegramPairing, only: [assign_telegram: 1, telegram_settings: 1]

  import TravelingPoetWeb.PoetComponents

  alias TravelingPoet.{Accounts, Credits, Geocoder, Payments, Poets, Preferences, Provisioner}
  alias TravelingPoet.Poets.{Poet, Presets}
  alias TravelingPoet.Topics
  alias TravelingPoet.Topics.Topic

  @impl true
  def mount(params, _session, socket) do
    user = socket.assigns.current_user
    poet = Poets.get_poet_by_user(user.id)

    socket =
      if params["purchased"] == "1",
        do: put_flash(socket, :info, "Credits added — happy travels!"),
        else: socket

    if connected?(socket) do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Settings")
     |> assign(:user, user)
     |> assign(:poet, poet)
     |> assign_push()
     |> assign_telegram()
     |> assign(:packs, Credits.packs())
     |> assign(:reading_list, Geocoder.reading_list())
     |> assign(:payments_mock, Payments.mock?())
     |> assign_credits()
     |> assign(:stops, (poet && Poets.list_stops(poet.id)) || [])
     |> assign(:stop_query, "")
     |> assign(:stop_results, [])
     |> assign(:stop_error, nil)
     |> assign_topics()
     |> assign_learned()}
  end

  defp assign_topics(socket) do
    case socket.assigns.poet do
      nil ->
        socket |> assign(:topics, []) |> assign(:queued_excursions, [])

      poet ->
        socket
        |> assign(:topics, Topics.list(poet.id))
        |> assign(:queued_excursions, Topics.list_queued(poet.id))
    end
  end

  defp assign_learned(socket) do
    case socket.assigns.poet do
      nil ->
        socket |> assign(:learned, []) |> assign(:dismissed, [])

      poet ->
        socket
        |> assign(:learned, Preferences.list_active(poet.id))
        |> assign(:dismissed, Preferences.list_dismissed(poet.id))
    end
  end

  defp source_label("tap"), do: "you tapped this"
  defp source_label("chat"), do: "you said this in chat"
  defp source_label("settings"), do: "you set this"
  defp source_label("onboarding"), do: "from your setup"
  defp source_label("reaction"), do: "from your reaction"
  defp source_label("marker"), do: "from your markers"
  defp source_label(_), do: "learned"

  @impl true
  def handle_event("push_" <> _ = event, params, socket),
    do: TravelingPoetWeb.PushNotifications.handle_event(event, params, socket)

  @impl true
  def handle_event("telegram_" <> _ = event, params, socket),
    do: TravelingPoetWeb.TelegramPairing.handle_event(event, params, socket)

  @impl true
  def handle_event("dismiss_preference", %{"id" => id}, socket) do
    poet = socket.assigns.poet

    with {id, ""} <- Integer.parse(id),
         pref when not is_nil(pref) <- Preferences.get(poet.id, id),
         {:ok, _} <- Preferences.dismiss(pref) do
      {:noreply, assign_learned(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("restore_preference", %{"id" => id}, socket) do
    poet = socket.assigns.poet

    with {id, ""} <- Integer.parse(id),
         pref when not is_nil(pref) <- Preferences.get(poet.id, id),
         {:ok, _} <- Preferences.restore(pref) do
      {:noreply, assign_learned(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  ## Topics

  @impl true
  def handle_event("add_topic", %{"label" => label} = params, socket) do
    poet = socket.assigns.poet

    case String.trim(label || "") do
      "" ->
        {:noreply, socket}

      label ->
        attrs = %{label: label, kind: parse_kind(params["kind"])}

        case Topics.create(poet.id, attrs) do
          {:ok, _} ->
            {:noreply, assign_topics(socket)}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, topic_error(changeset))}
        end
    end
  end

  @impl true
  def handle_event("save_topic", %{"topic_id" => id} = params, socket) do
    with_topic(socket, id, fn topic ->
      attrs = %{
        kind: parse_kind(params["kind"]),
        every_days: parse_cadence(params["every_days"], topic.every_days)
      }

      # A half-retyped label keeps the current one, as the poet's name does.
      attrs =
        case String.trim(params["label"] || "") do
          "" -> attrs
          label -> Map.put(attrs, :label, label)
        end

      case Topics.update(topic, attrs) do
        {:ok, _} -> {:noreply, assign_topics(socket)}
        {:error, changeset} -> {:noreply, put_flash(socket, :error, topic_error(changeset))}
      end
    end)
  end

  @impl true
  def handle_event("keep_topic", %{"id" => id}, socket) do
    with_topic(socket, id, fn topic ->
      {:ok, _} = Topics.keep(topic)
      {:noreply, assign_topics(socket)}
    end)
  end

  @impl true
  def handle_event("pause_topic", %{"id" => id}, socket) do
    with_topic(socket, id, fn topic ->
      {:ok, _} = Topics.pause(topic)
      {:noreply, assign_topics(socket)}
    end)
  end

  @impl true
  def handle_event("resume_topic", %{"id" => id}, socket) do
    with_topic(socket, id, fn topic ->
      {:ok, _} = Topics.resume(topic)
      {:noreply, assign_topics(socket)}
    end)
  end

  @impl true
  def handle_event("remove_topic", %{"id" => id}, socket) do
    with_topic(socket, id, fn topic ->
      {:ok, _} = Topics.delete(topic)
      {:noreply, assign_topics(socket)}
    end)
  end

  @impl true
  def handle_event("remove_excursion", %{"id" => id}, socket) do
    poet = socket.assigns.poet

    with {id, ""} <- Integer.parse(to_string(id)),
         %{status: "queued"} = excursion <- Topics.get_excursion(poet.id, id),
         {:ok, _} <- Topics.delete_excursion(excursion) do
      {:noreply, assign_topics(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save_user", params, socket) do
    user = socket.assigns.user

    case String.trim(params["name"] || "") do
      "" ->
        {:noreply, socket}

      name ->
        case Accounts.update_user(user, %{name: name}) do
          {:ok, updated} -> {:noreply, socket |> assign(:user, updated) |> assign_credits()}
          {:error, _} -> {:noreply, put_flash(socket, :error, "Could not save your name.")}
        end
    end
  end

  @impl true
  def handle_event("save_poet", params, socket) do
    poet = socket.assigns.poet

    interests = Presets.split_interests(params["interests"])

    # The form auto-saves on every keystroke and the changeset requires a
    # name, so a half-retyped (blank) name keeps the current one instead of
    # flashing an error mid-edit.
    name =
      case String.trim(params["poet_name"] || "") do
        "" -> poet.name
        trimmed -> trimmed
      end

    settings =
      (poet.settings || %{})
      |> Map.put("stay_duration_days", parse_days(params["stay_duration_days"]))
      |> Map.put("telegram_notify", params["telegram_notify"] == "on")
      |> Map.put("verbosity", parse_verbosity(params["verbosity"]))
      # Kept in step with the column so the two don't drift: the column is
      # what reaches the agent every run, this copy is what gets baked into
      # the workspace on the next provision.
      |> Map.put("user_interests", interests)

    attrs = %{
      name: name,
      personality: params["personality"],
      interests: interests,
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

  ## Currently reading

  @impl true
  def handle_event("toggle_book", %{"idx" => idx}, socket) do
    case Enum.at(socket.assigns.reading_list, String.to_integer(idx)) do
      nil ->
        {:noreply, socket}

      book ->
        items = reading_items(socket.assigns.poet)

        items =
          if Enum.any?(items, &(&1["title"] == book["title"])),
            do: Enum.reject(items, &(&1["title"] == book["title"])),
            else: items ++ [book]

        {:noreply, save_reading(socket, items)}
    end
  end

  @impl true
  def handle_event("add_book", %{"title" => title}, socket) do
    case String.trim(title) do
      "" ->
        {:noreply, socket}

      title ->
        items = reading_items(socket.assigns.poet)

        if Enum.any?(items, &(&1["title"] == title)),
          do: {:noreply, socket},
          else: {:noreply, save_reading(socket, items ++ [%{"title" => title, "author" => ""}])}
    end
  end

  @impl true
  def handle_event("remove_book", %{"title" => title}, socket) do
    items = socket.assigns.poet |> reading_items() |> Enum.reject(&(&1["title"] == title))
    {:noreply, save_reading(socket, items)}
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
        Provisioner.provision_in_background(socket.assigns.user)

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
        case TravelingPoet.Geocoder.Limiter.search(q) do
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
  def handle_event("release_hold", _params, socket) do
    {:ok, poet} = Poets.release_hold(socket.assigns.poet)

    {:noreply,
     socket
     |> assign(:poet, poet)
     |> put_flash(:info, "#{poet.name} is free to move on with the next run.")}
  end

  @impl true
  def handle_event("remove_stop", %{"id" => id}, socket) do
    Poets.remove_stop(socket.assigns.poet.id, String.to_integer(id))
    {:noreply, assign(socket, :stops, Poets.list_stops(socket.assigns.poet.id))}
  end

  @impl true
  def handle_info({:telegram_paired, _} = msg, socket),
    do: TravelingPoetWeb.TelegramPairing.handle_info(msg, socket)

  @impl true
  def handle_info({:credits_updated, _balance}, socket) do
    {:noreply,
     socket
     |> assign(:user, Accounts.get_user!(socket.assigns.user.id))
     |> assign_credits()}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_credits(socket) do
    user = socket.assigns.user
    poet = socket.assigns.poet

    socket
    |> assign(:current_user, user)
    |> assign(:balance, Credits.balance(user))
    |> assign(:runway, Credits.runway_days(user, poet))
    |> assign(:credits_low, Credits.low?(user, poet))
    |> assign(:credits_exhausted, Credits.exhausted?(user, poet))
    |> assign(:transactions, Credits.list_transactions(user, 10))
  end

  defp runway_text(nil), do: "Unlimited — this account is exempt from credits."
  defp runway_text(days) when days < 1, do: "Not enough for tomorrow's entry."

  defp runway_text(days),
    do:
      "≈ #{trunc(days)} #{if trunc(days) == 1, do: "day", else: "days"} of travel at your poet's pace."

  defp tx_label("grant_signup"), do: "Welcome credits"
  defp tx_label("grant_referral"), do: "Referral bonus"
  defp tx_label("grant_grandfather"), do: "Early traveler bonus"
  defp tx_label("grant_admin"), do: "Bonus credits"
  defp tx_label("purchase"), do: "Purchase"
  defp tx_label("debit_daily_run"), do: "Daily journey"
  defp tx_label("refund"), do: "Refund"
  defp tx_label("admin_adjust"), do: "Adjustment"
  defp tx_label(other), do: other

  defp signed(milli) when milli >= 0, do: "+" <> Credits.format(milli)
  defp signed(milli), do: "−" <> Credits.format(-milli)

  defp dollars(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2) |> String.replace(~r/\.00$/, "")}"

  defp reading_items(poet), do: get_in(poet.currently_reading || %{}, ["items"]) || []

  defp save_reading(socket, items) do
    case Poets.update_poet(socket.assigns.poet, %{currently_reading: %{"items" => items}}) do
      {:ok, updated} -> assign(socket, :poet, updated)
      {:error, _} -> put_flash(socket, :error, "Could not save the reading list.")
    end
  end

  # Indices of the curated books the poet is reading (for the chips) and the
  # free-text ones that aren't on the curated list.
  defp selected_book_indices(poet, reading_list) do
    titles = poet |> reading_items() |> MapSet.new(& &1["title"])

    reading_list
    |> Enum.with_index()
    |> Enum.filter(fn {book, _} -> MapSet.member?(titles, book["title"]) end)
    |> MapSet.new(fn {_, idx} -> idx end)
  end

  defp custom_books(poet, reading_list) do
    curated = MapSet.new(reading_list, & &1["title"])
    poet |> reading_items() |> Enum.reject(&MapSet.member?(curated, &1["title"]))
  end

  defp parse_days(str) do
    case Integer.parse(to_string(str)) do
      {n, _} when n in 1..30 -> n
      _ -> 3
    end
  end

  defp parse_verbosity(v) when v in ["brief", "balanced", "expansive"], do: v
  defp parse_verbosity(_), do: "balanced"

  defp with_topic(socket, id, fun) do
    poet = socket.assigns.poet

    with {id, ""} <- Integer.parse(to_string(id)),
         %Topic{} = topic <- Topics.get(poet.id, id) do
      fun.(topic)
    else
      _ -> {:noreply, socket}
    end
  end

  defp parse_kind(kind) when kind in ["professional", "personal"], do: kind
  defp parse_kind(_), do: nil

  defp parse_cadence(str, current) do
    case Integer.parse(to_string(str)) do
      {n, _} when n in 3..30 -> n
      _ -> current
    end
  end

  defp topic_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
    |> then(&"Could not save the topic: #{&1}.")
  end

  defp cadence_options,
    do: [{5, "every 5 days"}, {7, "every week"}, {10, "every 10 days"}, {14, "every two weeks"}]

  defp kind_options,
    do: [{"", "not sure"}, {"professional", "work or study"}, {"personal", "passion"}]

  defp topic_status_label(%Topic{status: "proposed"}), do: "proposed by your poet"
  defp topic_status_label(%Topic{status: "paused"}), do: "paused"
  defp topic_status_label(%Topic{source: "chat"}), do: "from chat"
  defp topic_status_label(_), do: nil

  # "last excursion Sep 12, next in 3 days" for an active topic; nothing for
  # the others (a paused topic has no next, a proposal is not yet followed).
  defp topic_schedule(%Topic{status: "active"} = topic, poet_name) do
    last =
      case Topics.last_excursion_on(topic) do
        nil -> "no excursion yet"
        date -> "last excursion " <> Calendar.strftime(date, "%b %-d")
      end

    next =
      case Topics.days_until_due(topic) do
        :due -> "next on the first day #{poet_name} stays put"
        1 -> "next in a day"
        n -> "next in #{n} days"
      end

    last <> ", " <> next
  end

  defp topic_schedule(_topic, _poet_name), do: nil

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
    <Layouts.app
      flash={@flash}
      current_user={assigns[:current_user]}
      credits_low={assigns[:credits_low]}
      active_tab={:settings}
    >
      <div class="mx-auto max-w-xl py-8">
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-2xl font-semibold">Settings</h1>
          <.link navigate={~p"/journal"} class="btn btn-ghost btn-sm">← Journal</.link>
        </div>

        <div :if={@poet}>
          <p class="text-xs opacity-60 -mt-4 mb-4">Changes save automatically.</p>

          <form id="user-settings-form" phx-change="save_user" class="mb-4">
            <label class="block">
              <span class="text-sm font-medium">Your name</span>
              <input
                type="text"
                name="name"
                phx-debounce="750"
                value={@user.name}
                class="input input-bordered w-full mt-1"
              />
              <span class="text-xs opacity-50">How {@poet.name} addresses you.</span>
            </label>
          </form>

          <form id="poet-settings-form" phx-change="save_poet" class="space-y-4">
            <label class="block">
              <span class="text-sm font-medium">Poet's name</span>
              <input
                type="text"
                name="poet_name"
                phx-debounce="750"
                value={@poet.name}
                class="input input-bordered w-full mt-1"
              />
              <span class="text-xs opacity-50">
                Shows in the journal right away; the poet's own introduction updates on
                the next repack, and the journal link keeps its current address.
              </span>
            </label>

            <label class="block">
              <span class="text-sm font-medium">{@poet.name}'s personality</span>
              <textarea
                name="personality"
                phx-debounce="750"
                class="textarea textarea-bordered w-full mt-1"
              >{@poet.personality}</textarea>
            </label>

            <label class="block">
              <span class="text-sm font-medium">What you want {@poet.name} to look for</span>
              <input
                type="text"
                name="interests"
                phx-debounce="750"
                value={Enum.join(@poet.interests || [], ", ")}
                placeholder="street food, bridges, hidden gardens"
                class="input input-bordered w-full mt-1"
              />
              <span class="text-xs opacity-50">
                Comma separated. Takes effect on tomorrow's entry.
              </span>
            </label>

            <div>
              <span class="text-sm font-medium">What {@poet.name} is reading</span>
              <div class="mt-2">
                <.book_chips
                  books={@reading_list}
                  selected={selected_book_indices(@poet, @reading_list)}
                  event="toggle_book"
                />
              </div>
              <ul :if={custom_books(@poet, @reading_list) != []} class="mt-2 space-y-1">
                <li
                  :for={book <- custom_books(@poet, @reading_list)}
                  class="flex items-center gap-2 text-sm"
                >
                  <span class="flex-1">{book["title"]}</span>
                  <button
                    type="button"
                    phx-click="remove_book"
                    phx-value-title={book["title"]}
                    class="btn btn-ghost btn-xs"
                    title="Remove"
                  >
                    ✕
                  </button>
                </li>
              </ul>
            </div>

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

            <p :if={@poet.hold_until} class="text-sm flex items-center gap-2">
              <span>
                Staying put through {Calendar.strftime(@poet.hold_until, "%B %-d")}, as you asked in chat.
              </span>
              <button type="button" phx-click="release_hold" class="btn btn-ghost btn-xs">
                Let it move on
              </button>
            </p>

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

          <form id="add-book-form" phx-submit="add_book" class="flex gap-2 mt-3">
            <input
              type="text"
              name="title"
              class="input input-bordered input-sm flex-1"
              placeholder="Add another book for the road…"
            />
            <button type="submit" class="btn btn-sm">Add</button>
          </form>

          <div class="divider"></div>

          <section id="topics">
            <h2 class="text-lg font-semibold mb-1">Topics {@poet.name} follows for you</h2>
            <p class="text-sm opacity-60 mb-3">
              Beyond places: a field you work in, a passion you keep. Every so often {@poet.name} takes a day off the road for an excursion into one of these, a conference, a festival, a lab, a company, and writes back about it. Tell {@poet.name} in chat, or add one here.
            </p>

            <p :if={@topics == []} class="text-sm opacity-50 mb-2">
              None yet.
            </p>

            <ul class="space-y-2">
              <li
                :for={topic <- @topics}
                id={"topic-#{topic.id}"}
                class={[
                  "p-2 rounded-lg border border-base-200",
                  topic.status == "paused" && "opacity-60"
                ]}
              >
                <form
                  id={"topic-form-#{topic.id}"}
                  phx-change="save_topic"
                  phx-value-id={topic.id}
                  class="flex flex-wrap items-center gap-2"
                >
                  <input type="hidden" name="topic_id" value={topic.id} />
                  <input
                    type="text"
                    name="label"
                    phx-debounce="750"
                    value={topic.label}
                    class="input input-bordered input-sm flex-1 min-w-40"
                  />
                  <select name="kind" class="select select-bordered select-sm">
                    <option
                      :for={{value, label} <- kind_options()}
                      value={value}
                      selected={(topic.kind || "") == value}
                    >
                      {label}
                    </option>
                  </select>
                  <select
                    name="every_days"
                    class="select select-bordered select-sm"
                    disabled={topic.status == "proposed"}
                  >
                    <option
                      :for={{days, label} <- cadence_options()}
                      value={days}
                      selected={topic.every_days == days}
                    >
                      {label}
                    </option>
                  </select>
                </form>
                <div class="flex items-center gap-2 mt-1 text-xs opacity-60">
                  <span :if={topic_status_label(topic)}>{topic_status_label(topic)}</span>
                  <span :if={topic_schedule(topic, @poet.name)}>{topic_schedule(topic, @poet.name)}</span>
                  <span :if={topic.evidence["quote"]} class="italic">
                    &ldquo;{topic.evidence["quote"]}&rdquo;
                  </span>
                  <span class="flex-1"></span>
                  <button
                    :if={topic.status == "proposed"}
                    type="button"
                    phx-click="keep_topic"
                    phx-value-id={topic.id}
                    class="btn btn-primary btn-xs"
                  >
                    Keep
                  </button>
                  <button
                    :if={topic.status == "proposed"}
                    type="button"
                    phx-click="remove_topic"
                    phx-value-id={topic.id}
                    class="btn btn-ghost btn-xs"
                  >
                    Not this
                  </button>
                  <button
                    :if={topic.status == "active"}
                    type="button"
                    phx-click="pause_topic"
                    phx-value-id={topic.id}
                    class="btn btn-ghost btn-xs"
                  >
                    Pause
                  </button>
                  <button
                    :if={topic.status == "paused"}
                    type="button"
                    phx-click="resume_topic"
                    phx-value-id={topic.id}
                    class="btn btn-ghost btn-xs"
                  >
                    Resume
                  </button>
                  <button
                    :if={topic.status != "proposed"}
                    type="button"
                    phx-click="remove_topic"
                    phx-value-id={topic.id}
                    class="btn btn-ghost btn-xs"
                    title="Remove"
                  >
                    ✕
                  </button>
                </div>
              </li>
            </ul>

            <div :if={@queued_excursions != []} class="mt-3">
              <h3 class="text-sm font-medium mb-1">Asked for in chat</h3>
              <ul id="queued-excursions" class="space-y-1">
                <li
                  :for={x <- @queued_excursions}
                  id={"excursion-#{x.id}"}
                  class="flex items-center gap-2 text-sm p-2 rounded-lg bg-base-200"
                >
                  <span class="flex-1">
                    {x.requested_venue}
                    <span class="opacity-60">for {x.topic.label}</span>
                  </span>
                  <span class="text-xs opacity-60">on the next day {@poet.name} stays put</span>
                  <button
                    type="button"
                    phx-click="remove_excursion"
                    phx-value-id={x.id}
                    class="btn btn-ghost btn-xs"
                    title="Remove"
                  >
                    ✕
                  </button>
                </li>
              </ul>
            </div>

            <form id="add-topic-form" phx-submit="add_topic" class="flex gap-2 mt-3">
              <input
                type="text"
                name="label"
                class="input input-bordered input-sm flex-1"
                placeholder="Add a topic, like kit airplanes or embodied minds"
              />
              <select name="kind" class="select select-bordered select-sm">
                <option :for={{value, label} <- kind_options()} value={value}>{label}</option>
              </select>
              <button type="submit" class="btn btn-sm">Add</button>
            </form>
          </section>

          <div class="divider"></div>

          <section id="learned">
            <h2 class="text-lg font-semibold mb-1">What {@poet.name} has learned about you</h2>
            <p class="text-sm opacity-60 mb-3">
              Picked up from what you tap under an entry and what you say in chat. {@poet.name} applies these on its own — remove anything that isn't right.
            </p>

            <p :if={@learned == []} class="text-sm opacity-50">
              Nothing yet. Answer a question under an entry, or just tell {@poet.name} in chat what you'd rather read about.
            </p>

            <ul class="space-y-2">
              <li
                :for={pref <- @learned}
                class="flex items-start gap-2 p-2 rounded-lg border border-base-200"
              >
                <div class="flex-1">
                  <div class="text-sm">
                    <span :if={pref.polarity == "avoid"} class="opacity-60">less: </span>{pref.label}
                  </div>
                  <div class="text-xs opacity-50">
                    {source_label(pref.source)}
                    <span :if={pref.weight > 1}>· mentioned {pref.weight}×</span>
                    <span :if={pref.evidence["quote"]} class="italic">
                      · &ldquo;{pref.evidence["quote"]}&rdquo;
                    </span>
                  </div>
                </div>
                <button
                  phx-click="dismiss_preference"
                  phx-value-id={pref.id}
                  class="btn btn-ghost btn-xs"
                  title="Remove"
                >
                  ✕
                </button>
              </li>
            </ul>

            <details :if={@dismissed != []} class="mt-3">
              <summary class="text-xs opacity-50 cursor-pointer">
                Removed ({length(@dismissed)})
              </summary>
              <ul class="mt-2 space-y-1">
                <li :for={pref <- @dismissed} class="flex items-center gap-2 text-sm opacity-60">
                  <span class="flex-1">{pref.label}</span>
                  <button
                    phx-click="restore_preference"
                    phx-value-id={pref.id}
                    class="btn btn-ghost btn-xs"
                  >
                    restore
                  </button>
                </li>
              </ul>
            </details>
          </section>

          <div class="divider"></div>

          <h2 class="font-semibold mb-2">Credits</h2>
          <div class="flex items-baseline gap-3">
            <span class="text-3xl font-semibold" id="credits-balance">
              {Credits.format(@balance)}
            </span>
            <span class="text-sm opacity-60">credits</span>
          </div>
          <p class={["text-sm mt-1", @credits_low && "text-warning"]}>{runway_text(@runway)}</p>
          <p :if={@credits_exhausted} class="text-sm text-error mt-1">
            Your poet is resting until you top up.
          </p>
          <p class="text-xs opacity-60 mt-2 mb-3">
            Each day's journey costs {Credits.format(Credits.daily_run_cost(@poet))}
            {if Poet.mode(@poet) == "scout", do: "credits (Trip Scout)", else: "credit (Wanderer)"};
            chatting and drawings are included.
          </p>

          <div class="grid grid-cols-2 sm:grid-cols-4 gap-2 mb-3">
            <form :for={pack <- @packs} method="post" action={~p"/credits/checkout"}>
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <input type="hidden" name="pack" value={pack.id} />
              <button type="submit" class="btn btn-outline btn-sm w-full flex-col h-auto py-2">
                <span class="font-semibold">{pack.credits} credits</span>
                <span class="text-xs opacity-70">{dollars(pack.cents)}</span>
              </button>
            </form>
          </div>
          <p :if={@payments_mock} class="text-xs text-warning mb-3">
            Payments are in test mode — purchases are mocked and free.
          </p>

          <details :if={@transactions != []} class="text-sm">
            <summary class="cursor-pointer opacity-70">Recent activity</summary>
            <ul class="mt-2 space-y-1">
              <li :for={tx <- @transactions} class="flex justify-between gap-2">
                <span>{tx_label(tx.kind)}</span>
                <span class="opacity-60 text-xs">
                  {Calendar.strftime(tx.inserted_at, "%b %-d")}
                </span>
                <span class={["tabular-nums", tx.amount < 0 && "opacity-70"]}>
                  {signed(tx.amount)}
                </span>
              </li>
            </ul>
          </details>

          <div class="divider"></div>

          <h2 class="font-semibold mb-2">Your book</h2>
          <p class="text-sm opacity-70 mb-3">
            The whole journal as one printable notebook: a chapter for every place,
            a table of contents, every drawing with what it was drawn from, every
            source written out. Print it or save it as a PDF from your browser. Free.
          </p>
          <a href={~p"/journal/book"} target="_blank" class="btn btn-outline btn-sm" id="open-book">
            <.icon name="hero-book-open" class="size-4" /> Open the book
          </a>

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
                <span :if={stop.source == "chat"} class="badge badge-ghost badge-xs ml-1">
                  asked in chat
                </span>
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

          <.push_settings push={@push} poet={@poet} />

          <div class="divider"></div>

          <.telegram_settings telegram={@telegram} user={@user} />

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
