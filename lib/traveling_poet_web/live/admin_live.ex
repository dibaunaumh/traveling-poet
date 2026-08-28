defmodule TravelingPoetWeb.AdminLive do
  use TravelingPoetWeb, :live_view

  import Ecto.Query

  alias TravelingPoet.{Accounts, Credits, Repo, Usage}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Poets.Poet

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin — costs")
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

    socket
    |> assign(:rows, rows)
    |> assign(:total_week, total_week)
  end

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
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
