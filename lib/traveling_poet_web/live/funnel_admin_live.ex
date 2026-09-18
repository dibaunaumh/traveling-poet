defmodule TravelingPoetWeb.FunnelAdminLive do
  @moduledoc """
  Where visitors drop off, from first page view to a published first entry.
  Numbers come from `TravelingPoet.Analytics` (anonymous visit events) and
  from the users who signed up in the chosen window.
  """

  use TravelingPoetWeb, :live_view

  alias TravelingPoet.Analytics

  @ranges [7, 30, 90]

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Admin: funnel") |> assign(:days, 7) |> load()}
  end

  @impl true
  def handle_event("range", %{"days" => days}, socket) do
    days = String.to_integer(days)
    days = if days in @ranges, do: days, else: 7
    {:noreply, socket |> assign(:days, days) |> load()}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    since =
      Date.utc_today()
      |> Date.add(-(socket.assigns.days - 1))
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    funnel = Analytics.funnel(since)
    top = funnel |> List.first() |> elem(1)
    daily = Analytics.daily_visitors(since)

    socket
    |> assign(:ranges, @ranges)
    |> assign(:funnel, funnel_rows(funnel, top))
    |> assign(:daily, daily)
    |> assign(:daily_max, daily |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end))
    |> assign(:pages, Analytics.pages(since))
    |> assign(:clicks, Analytics.clicks(since))
    |> assign(:referrers, Analytics.top(since, :referrer_host))
    |> assign(:sources, Analytics.top(since, :utm_source))
    |> assign(:viewports, Analytics.top(since, :viewport))
    |> assign(:stuck, Analytics.stuck_in_onboarding(since))
  end

  defp funnel_rows(funnel, top) do
    funnel
    |> Enum.with_index()
    |> Enum.map(fn {{label, n}, idx} ->
      prev = if idx == 0, do: n, else: funnel |> Enum.at(idx - 1) |> elem(1)

      %{
        label: label,
        n: n,
        of_prev: if(idx == 0, do: nil, else: Analytics.pct(n, prev)),
        of_top: Analytics.pct(n, top),
        # The account steps start a new population (sign-ups), marked so the
        # jump from visitors to users reads as a boundary, not a drop.
        boundary?: idx == 3
      }
    end)
  end

  defp pct_label(nil), do: ""
  defp pct_label(p), do: "#{p}%"

  defp bar_width(_n, 0), do: 0
  defp bar_width(n, max), do: max(round(n * 100 / max), 2)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={assigns[:current_user]}
      credits_low={assigns[:credits_low]}
    >
      <div class="mx-auto max-w-5xl py-8 space-y-8">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-semibold">Visitor funnel</h1>
          <div class="flex items-center gap-2">
            <button
              :for={d <- @ranges}
              phx-click="range"
              phx-value-days={d}
              class={["btn btn-sm", if(d == @days, do: "btn-primary", else: "btn-ghost")]}
            >
              {d} days
            </button>
            <.link navigate={~p"/admin"} class="btn btn-sm btn-ghost">Fleet</.link>
            <button phx-click="refresh" class="btn btn-sm">Refresh</button>
          </div>
        </div>

        <section>
          <table class="table table-sm" id="funnel">
            <thead>
              <tr>
                <th>Step</th>
                <th class="text-right">Count</th>
                <th class="text-right">Of previous</th>
                <th class="text-right">Of visitors</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @funnel} class={row.boundary? && "border-t-2 border-base-300"}>
                <td>{row.label}</td>
                <td class="text-right font-mono">{row.n}</td>
                <td class="text-right font-mono opacity-70">{pct_label(row.of_prev)}</td>
                <td class="text-right font-mono opacity-70">{pct_label(row.of_top)}</td>
              </tr>
            </tbody>
          </table>
          <p class="text-xs opacity-60 mt-2">
            Visitors are anonymous ids that change daily, so one person on three days counts
            three times. Rows from "Signed up" down count the accounts created in this window.
          </p>
        </section>

        <section>
          <h2 class="font-semibold mb-2">Visitors per day</h2>
          <div class="flex items-end gap-1 h-24" id="daily-visitors">
            <div
              :for={{date, n} <- @daily}
              class="flex-1 bg-primary/60 rounded-t min-h-px"
              style={"height: #{bar_width(n, @daily_max)}%"}
              title={"#{date}: #{n}"}
            >
            </div>
          </div>
        </section>

        <section class="overflow-x-auto">
          <h2 class="font-semibold mb-2">Pages</h2>
          <table class="table table-sm" id="pages">
            <thead>
              <tr>
                <th>Path</th>
                <th class="text-right">Visitors</th>
                <th class="text-right">Bounced</th>
                <th class="text-right">Median time</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={p <- @pages}>
                <td class="font-mono text-xs">{p.path}</td>
                <td class="text-right font-mono">{p.visitors}</td>
                <td class="text-right font-mono">{pct_label(p.bounce_pct)}</td>
                <td class="text-right font-mono">{p.median_s && "#{p.median_s}s"}</td>
              </tr>
            </tbody>
          </table>
          <p class="text-xs opacity-60 mt-2">
            Bounced: the only page that visitor opened that day, no click, under 10 seconds.
          </p>
        </section>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-8">
          <section>
            <h2 class="font-semibold mb-2">Clicks</h2>
            <table class="table table-sm" id="clicks">
              <thead>
                <tr>
                  <th>What</th><th class="text-right">Clicks</th><th class="text-right">Visitors</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{label, clicks, visitors} <- @clicks}>
                  <td class="font-mono text-xs">{label}</td>
                  <td class="text-right font-mono">{clicks}</td>
                  <td class="text-right font-mono">{visitors}</td>
                </tr>
              </tbody>
            </table>
          </section>

          <section class="space-y-6">
            <.top_table title="Referrers" rows={@referrers} empty="Direct visits only" />
            <.top_table title="Campaigns (utm_source or ref)" rows={@sources} empty="None" />
            <.top_table title="Devices" rows={@viewports} empty="None" />
          </section>
        </div>

        <section class="overflow-x-auto">
          <h2 class="font-semibold mb-2">Signed up, onboarding not finished</h2>
          <p :if={@stuck == []} class="text-sm opacity-60">Nobody in this window.</p>
          <table :if={@stuck != []} class="table table-sm" id="stuck">
            <thead>
              <tr>
                <th>Email</th><th>Last step</th><th>Signed up</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={u <- @stuck}>
                <td>{u.email}</td>
                <td>{u.step || "never opened"}</td>
                <td class="text-xs opacity-70">{Calendar.strftime(u.inserted_at, "%b %-d %H:%M")}</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :empty, :string, required: true

  defp top_table(assigns) do
    ~H"""
    <div>
      <h2 class="font-semibold mb-2">{@title}</h2>
      <p :if={@rows == []} class="text-sm opacity-60">{@empty}</p>
      <table :if={@rows != []} class="table table-sm">
        <tbody>
          <tr :for={{value, n} <- @rows}>
            <td class="font-mono text-xs">{value}</td>
            <td class="text-right font-mono">{n}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
