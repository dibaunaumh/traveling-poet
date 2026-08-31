defmodule TravelingPoetWeb.AdminLive do
  use TravelingPoetWeb, :live_view

  import Ecto.Query

  alias TravelingPoet.{Accounts, Credits, FleetHealth, OpenRouter, Repo, Usage}
  alias TravelingPoet.Accounts.Purge
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Poets.Poet

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin — fleet health & costs")
     |> load_fleet()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_fleet(socket)}
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

    rows =
      from(u in User,
        left_join: p in Poet,
        on: p.user_id == u.id,
        select: {u, p}
      )
      |> Repo.all()
      |> Enum.map(fn {user, poet} ->
        usage = rollup[user.id] || %{week_cost: 0, events: 0}

        %{
          user: user,
          poet: poet,
          today_cost: Usage.today_cost(user.id),
          week_cost: usage.week_cost,
          runs_today: Usage.today_count(user.id, "daily_run"),
          budget: user.daily_budget_cents
        }
      end)
      |> Enum.sort_by(& &1.week_cost, :desc)

    total_week = rows |> Enum.map(& &1.week_cost) |> Enum.sum()

    health = FleetHealth.report()

    socket
    |> assign(:rows, rows)
    |> assign(:total_week, total_week)
    |> assign(:health, health)
    |> assign(:health_summary, health_summary(health))
    |> assign(:openrouter, openrouter_banner())
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
            "OpenRouter key is out of credit — #{money(s.usage)} of #{money(s.limit)} used. " <>
              "Every poet's model turn is being rejected with a 402 until the key is topped up."
        }

      {:ok, %{low?: true} = s} ->
        %{
          class: "alert-warning",
          text: "OpenRouter key nearly spent: #{money(s.remaining)} left of #{money(s.limit)}."
        }

      {:ok, %{limit: nil}} ->
        nil

      {:ok, s} ->
        %{
          class: "alert-success",
          text: "OpenRouter key: #{money(s.remaining)} left of #{money(s.limit)}."
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
            <button phx-click="refresh" class="btn btn-sm">Refresh</button>
          </div>
        </div>

        <div :if={@openrouter} class={["alert mb-4", @openrouter.class]}>
          <span>{@openrouter.text}</span>
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

        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>User</th>
                <th>Poet</th>
                <th>Status</th>
                <th>Today</th>
                <th>7 days</th>
                <th>Runs today</th>
                <th>Daily budget</th>
                <th>Credits</th>
                <th>Delete</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @rows}>
                <td>{row.user.email}</td>
                <td>{(row.poet && row.poet.name) || "—"}</td>
                <td>
                  <span class={[
                    "badge badge-sm",
                    row.poet && row.poet.status == "active" && "badge-success",
                    row.poet && row.poet.status == "error" && "badge-error"
                  ]}>
                    {(row.poet && row.poet.status) || "no poet"}
                  </span>
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
                    data-confirm={"Permanently delete #{row.user.email}, their poet, journal, illustrations and sprite? This cannot be undone."}
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
