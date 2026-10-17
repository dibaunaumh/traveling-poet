defmodule TravelingPoetWeb.AdminLive do
  use TravelingPoetWeb, :live_view

  import Ecto.Query

  alias TravelingPoet.{Accounts, Credits, FirstEntry, FleetHealth, OpenRouter, Repo, Usage}
  alias TravelingPoet.Accounts.Purge
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Poets.Poet

  # The user table's filters, in the order the bar shows them. "new" is a
  # sign-up of the last seven days; "today" and "week" are readers seen since
  # UTC midnight and in the last seven days; "low" is a poet whose credits
  # run out within Credits.low_credits_days/0.
  @filters ~w(all problems new today week low)
  @filter_labels [
    {"all", "All"},
    {"problems", "Problems"},
    {"new", "New"},
    {"today", "Active today"},
    {"week", "Active this week"},
    {"low", "Low on credits"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin — fleet health & costs")
     |> assign(:filter, "all")
     |> assign(:filter_labels, @filter_labels)
     |> load_fleet()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_fleet(socket)}
  end

  @impl true
  def handle_event("filter", %{"f" => filter}, socket) when filter in @filters do
    {:noreply, assign(socket, :filter, filter)}
  end

  @impl true
  def handle_event("grant", %{"user_id" => user_id, "credits" => credits}, socket) do
    with {id, ""} <- Integer.parse(user_id),
         {n, ""} when n != 0 <- Integer.parse(credits),
         user when not is_nil(user) <- Accounts.get_user(id),
         {:ok, _} <- Credits.adjust(user, n, metadata: %{"by" => socket.assigns.current_user.id}) do
      {:noreply,
       socket |> put_flash(:info, "Adjusted #{user.email} by #{n} credits") |> load_fleet()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not adjust credits")}
    end
  end

  @impl true
  def handle_event("purge", %{"user_id" => user_id, "confirm_email" => confirm}, socket) do
    admin = socket.assigns.current_user

    with {id, ""} <- Integer.parse(user_id),
         false <- id == admin.id,
         {:ok, summary} <- Purge.purge(id, confirm) do
      {:noreply,
       socket
       |> put_flash(
         :info,
         "Deleted #{summary.email} — poet #{summary.poet || "none"}, " <>
           "#{summary.media_deleted}/#{summary.media_total} media, sprite #{summary.sprite}. " <>
           "Sign up again with that address to run onboarding."
       )
       |> load_fleet()}
    else
      true ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That's the account you're signed in as — sign in as another admin first."
         )}

      {:error, :email_mismatch} ->
        {:noreply, put_flash(socket, :error, "Email didn't match — nothing deleted.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "No such user.")}

      other ->
        {:noreply, put_flash(socket, :error, "Could not delete: #{inspect(other)}")}
    end
  end

  defp load_fleet(socket) do
    rollup = Usage.fleet_rollup() |> Map.new(&{&1.user_id, &1})
    health = FleetHealth.report()
    health_by_poet = Map.new(health, &{&1.poet.id, &1})
    now = DateTime.utc_now()

    rows =
      from(u in User,
        left_join: p in Poet,
        on: p.user_id == u.id,
        select: {u, p}
      )
      |> Repo.all()
      |> Enum.map(fn {user, poet} ->
        usage = rollup[user.id] || %{week_cost: 0, events: 0}
        turn_errors = Usage.today_count(user.id, "turn_error")

        %{
          user: user,
          poet: poet,
          trip: trip_summary(user, poet),
          today_cost: Usage.today_cost(user.id),
          week_cost: usage.week_cost,
          runs_today: Usage.today_count(user.id, "daily_run"),
          budget: user.daily_budget_cents,
          problems: problems(user, poet, poet && health_by_poet[poet.id], turn_errors),
          new?: since?(user.inserted_at, DateTime.add(now, -7, :day)),
          seen_today?: since?(user.last_seen_at, start_of_today(now)),
          seen_this_week?: since?(user.last_seen_at, DateTime.add(now, -7, :day)),
          low_credits?: low_credits?(user, poet)
        }
      end)
      |> Enum.sort_by(&{&1.problems == [], -&1.week_cost})

    total_week = rows |> Enum.map(& &1.week_cost) |> Enum.sum()

    socket
    |> assign(:rows, rows)
    |> assign(:total_week, total_week)
    |> assign(:health, health)
    |> assign(:health_summary, health_summary(health))
    |> assign(:openrouter, openrouter_banner())
  end

  # What is wrong with this poet right now, in the admin's words. Empty is
  # the normal case. A poet that stalled on 2026-10-17 was only visible as
  # one red "error" badge in a long table, and the four readers it concerned
  # waited an hour; this is what the page now leads with.
  defp problems(_user, nil, _health, _turn_errors), do: []

  defp problems(user, poet, health, turn_errors) do
    [
      poet.status == "error" && "setup failed",
      health && health.status == :failing && "missed today",
      health && health.status == :late && health.attempts_today > 0 &&
        "#{health.attempts_today} failed #{plural(health.attempts_today, "attempt")} today",
      FirstEntry.status(user, poet) == :exhausted && "first page never came",
      turn_errors > 0 && "#{turn_errors} turn #{plural(turn_errors, "error")} today"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp low_credits?(_user, nil), do: false
  defp low_credits?(user, poet), do: Credits.low?(user, poet)

  defp since?(nil, _since), do: false

  defp since?(%NaiveDateTime{} = at, since),
    do: since?(DateTime.from_naive!(at, "Etc/UTC"), since)

  defp since?(%DateTime{} = at, since), do: DateTime.compare(at, since) != :lt

  defp start_of_today(now),
    do: now |> DateTime.to_date() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

  defp visible(rows, "all"), do: rows
  defp visible(rows, "problems"), do: Enum.filter(rows, &(&1.problems != []))
  defp visible(rows, "new"), do: Enum.filter(rows, & &1.new?)
  defp visible(rows, "today"), do: Enum.filter(rows, & &1.seen_today?)
  defp visible(rows, "week"), do: Enum.filter(rows, & &1.seen_this_week?)
  defp visible(rows, "low"), do: Enum.filter(rows, & &1.low_credits?)

  defp filter_count(rows, filter), do: rows |> visible(filter) |> length()

  # The name is what identifies a reader now that Sign in with Apple hands
  # us relay addresses; the email stays one hover away for the purge form.
  defp display_name(%User{name: name}) when is_binary(name) and name != "", do: name
  defp display_name(%User{email: email}), do: email |> String.split("@") |> hd()

  # The calendar connection and the nearest trip on the books, for the row.
  defp trip_summary(user, poet) do
    calendar =
      cond do
        not TravelingPoet.GoogleCalendar.connected?(user) -> nil
        user.calendar_error -> "calendar: #{user.calendar_error}"
        true -> "calendar"
      end

    trip =
      poet &&
        poet.id
        |> TravelingPoet.Trips.list_by_status(~w(suggested planned scouting))
        |> List.first()

    %{calendar: calendar, trip: trip}
  end

  # The whole fleet runs on one OpenRouter key. When it is spent every model
  # turn 402s before it starts, which reaches the app as silent sprites — so
  # the balance belongs above the table that would otherwise just look broken.
  defp openrouter_banner do
    case OpenRouter.key_status() do
      {:ok, %{exhausted?: true} = s} ->
        %{
          class: "alert-error",
          text:
            "OpenRouter #{OpenRouter.scope_label(s)} is out — #{money(s.remaining)} left of #{money(s.limit)}. " <>
              "Every poet's model turn is being rejected with a 402 until the key is topped up."
        }

      {:ok, %{low?: true} = s} ->
        %{
          class: "alert-warning",
          text:
            "OpenRouter #{OpenRouter.scope_label(s)} nearly spent: #{money(s.remaining)} left of #{money(s.limit)}."
        }

      {:ok, %{limit: nil}} ->
        nil

      {:ok, s} ->
        %{
          class: "alert-success",
          text:
            "OpenRouter #{OpenRouter.scope_label(s)}: #{money(s.remaining)} left of #{money(s.limit)}."
        }

      {:error, :not_configured} ->
        nil

      {:error, reason} ->
        %{class: "alert-warning", text: "Could not read OpenRouter balance: #{inspect(reason)}"}
    end
  end

  defp money(nil), do: "?"
  defp money(n), do: "$#{:erlang.float_to_binary(n, decimals: 2)}"

  defp health_summary(health) do
    counts = Enum.frequencies_by(health, & &1.status)

    case Map.get(counts, :failing, 0) do
      0 -> "#{Map.get(counts, :ok, 0)} publishing, none missed"
      n -> "#{n} poet(s) missing their day"
    end
  end

  defp health_badge(:ok), do: "badge-success"
  defp health_badge(:late), do: "badge-warning"
  defp health_badge(:failing), do: "badge-error"
  defp health_badge(:never_published), do: "badge-warning"
  defp health_badge(:inactive), do: "badge-ghost"

  defp health_label(:never_published), do: "never published"
  defp health_label(status), do: to_string(status)

  defp cents(c), do: "$#{:erlang.float_to_binary(c / 100, decimals: 2)}"

  # Coarse on purpose: the question is "is this person still around", and
  # minutes vs hours vs days is the whole answer.
  defp ago(nil), do: "never"

  defp ago(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={assigns[:current_user]}
      credits_low={assigns[:credits_low]}
    >
      <div class="mx-auto max-w-5xl py-8">
        <div class="flex items-center justify-between mb-4">
          <h1 class="text-2xl font-semibold">Fleet health</h1>
          <div class="flex items-center gap-3">
            <span class="text-sm opacity-70">
              {@health_summary}
            </span>
            <.link navigate={~p"/admin/funnel"} class="btn btn-sm btn-ghost">Funnel</.link>
            <.link navigate={~p"/admin/change-stream"} class="btn btn-sm btn-ghost">
              Change stream
            </.link>
            <button phx-click="refresh" class="btn btn-sm">Refresh</button>
          </div>
        </div>

        <div :if={@openrouter} class={["alert mb-4", @openrouter.class]}>
          <span>{@openrouter.text}</span>
        </div>

        <div
          :if={Enum.any?(@rows, &(&1.problems != []))}
          id="needs-attention"
          class="alert alert-error mb-4 items-start"
        >
          <div>
            <p class="font-semibold">Needs attention</p>
            <ul class="mt-1 text-sm">
              <li :for={row <- Enum.filter(@rows, &(&1.problems != []))}>
                <b>{row.poet.name}</b>
                <span class="opacity-80">({display_name(row.user)})</span>: {Enum.join(
                  row.problems,
                  ", "
                )}
              </li>
            </ul>
          </div>
        </div>

        <div class="overflow-x-auto mb-10">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Poet</th>
                <th>Health</th>
                <th>Last published</th>
                <th>Latest entry</th>
                <th>Map says</th>
                <th>Attempts today</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={h <- @health} class={h.status == :failing && "bg-error/5"}>
                <td>{h.poet.name}</td>
                <td>
                  <span class={["badge badge-sm", health_badge(h.status)]}>
                    {health_label(h.status)}
                  </span>
                </td>
                <td class="tabular-nums">
                  {if h.hours_since_publish, do: "#{trunc(h.hours_since_publish)}h ago", else: "never"}
                </td>
                <td>
                  {h.entry_place || "—"}
                  <span
                    :if={h.excursion_label}
                    class="badge badge-info badge-xs"
                    title={"A day off the road, into #{h.excursion_label}"}
                  >
                    excursion
                  </span>
                  <span :if={h.last_entry_date} class="opacity-50 text-xs">
                    {h.last_entry_date}
                  </span>
                </td>
                <td>
                  {h.current_place || "—"}
                  <span
                    :if={h.drifted?}
                    class="badge badge-warning badge-xs"
                    title="The map has moved on but the journal hasn't caught up"
                  >
                    drifted
                  </span>
                </td>
                <td class="tabular-nums">{h.attempts_today}</td>
              </tr>
            </tbody>
          </table>
        </div>

        <div class="flex items-center justify-between mb-4">
          <h1 class="text-2xl font-semibold">Cost dashboard</h1>
          <div class="flex items-center gap-3">
            <span class="text-sm opacity-70">7-day total: <b>{cents(@total_week)}</b> (est.)</span>
            <button phx-click="refresh" class="btn btn-sm">Refresh</button>
          </div>
        </div>

        <div class="join mb-3" id="user-filters">
          <button
            :for={{key, label} <- @filter_labels}
            type="button"
            phx-click="filter"
            phx-value-f={key}
            class={["btn btn-xs join-item", @filter == key && "btn-active"]}
          >
            {label}
            <span class="opacity-60 tabular-nums">{filter_count(@rows, key)}</span>
          </button>
        </div>

        <div class="overflow-x-auto">
          <table class="table table-sm" id="users">
            <thead>
              <tr>
                <th>User</th>
                <th>Last seen</th>
                <th>Poet</th>
                <th>Status</th>
                <th>Trip</th>
                <th>Today</th>
                <th>7 days</th>
                <th>Runs today</th>
                <th>Daily budget</th>
                <th>Credits</th>
                <th>Delete</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- visible(@rows, @filter)} class={row.problems != [] && "bg-error/5"}>
                <td title={row.user.email}>{display_name(row.user)}</td>
                <td
                  class="tabular-nums"
                  title={row.user.last_seen_at && to_string(row.user.last_seen_at)}
                >
                  {ago(row.user.last_seen_at)}
                </td>
                <td>{(row.poet && row.poet.name) || "—"}</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    row.poet && row.poet.status == "active" && "badge-success",
                    row.poet && row.poet.status == "error" && "badge-error"
                  ]}>
                    {(row.poet && row.poet.status) || "no poet"}
                  </span>
                  <span :for={problem <- row.problems} class="badge badge-error badge-xs ml-1">
                    {problem}
                  </span>
                </td>
                <td class="text-xs">
                  <span :if={row.trip.calendar} class="badge badge-ghost badge-xs">
                    {row.trip.calendar}
                  </span>
                  <span :if={row.trip.trip}>
                    {row.trip.trip.name} {row.trip.trip.status}
                    <span :if={row.trip.trip.scout_from} class="opacity-60">
                      from {row.trip.trip.scout_from}
                    </span>
                  </span>
                  <span :if={!row.trip.calendar and !row.trip.trip} class="opacity-40">—</span>
                </td>
                <td>{cents(row.today_cost)}</td>
                <td>{cents(row.week_cost)}</td>
                <td>{row.runs_today}</td>
                <td>
                  {cents(row.budget)}
                  <span :if={row.user.quota_exempt} class="badge badge-ghost badge-xs">exempt</span>
                </td>
                <td>
                  <form phx-submit="grant" class="flex items-center gap-1">
                    <span class="tabular-nums">{Credits.format(row.user.credits_balance || 0)}</span>
                    <input type="hidden" name="user_id" value={row.user.id} />
                    <input
                      type="number"
                      name="credits"
                      placeholder="±"
                      class="input input-bordered input-xs w-16"
                    />
                    <button type="submit" class="btn btn-xs">Grant</button>
                  </form>
                </td>
                <td>
                  <%!-- Typing the address back is the guard: deletion takes the
                        poet, the journal and the sprite with it, and there is
                        nothing to restore from. --%>
                  <form
                    :if={row.user.id != @current_user.id}
                    phx-submit="purge"
                    class="flex items-center gap-1"
                    data-confirm={"Permanently delete #{display_name(row.user)} (#{row.user.email}), their poet, journal, illustrations and sprite? This cannot be undone."}
                  >
                    <input type="hidden" name="user_id" value={row.user.id} />
                    <input
                      type="text"
                      name="confirm_email"
                      placeholder="type email"
                      autocomplete="off"
                      class="input input-bordered input-xs w-40"
                    />
                    <button type="submit" class="btn btn-xs btn-error btn-outline">Delete</button>
                  </form>
                  <span :if={row.user.id == @current_user.id} class="text-xs opacity-40">
                    signed in
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
