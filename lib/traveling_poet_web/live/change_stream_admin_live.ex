defmodule TravelingPoetWeb.ChangeStreamAdminLive do
  @moduledoc """
  Admin page for the change stream: register receivers, watch their health,
  ping, pause, retry, backfill, delete. See `TravelingPoet.ChangeStream` for
  what a receiver gets.
  """

  use TravelingPoetWeb, :live_view

  alias TravelingPoet.ChangeStream
  alias TravelingPoet.ChangeStream.Backfill

  @refresh_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Admin — change stream")
     |> assign(:new_secret, nil)
     |> load()}
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("dismiss_secret", _params, socket),
    do: {:noreply, assign(socket, :new_secret, nil)}

  def handle_event("register", %{"url" => url, "auth_token" => token}, socket) do
    case ChangeStream.create_endpoint(%{"url" => url, "auth_token" => token}) do
      {:ok, endpoint} ->
        {:noreply,
         socket
         |> assign(:new_secret, %{url: endpoint.url, secret: endpoint.signing_secret})
         |> put_flash(
           :info,
           "Registered #{endpoint.url}. Run a backfill to send it the current data."
         )
         |> load()}

      {:error, changeset} ->
        errors =
          Enum.map_join(changeset.errors, "; ", fn {field, {msg, _}} -> "#{field} #{msg}" end)

        {:noreply, put_flash(socket, :error, "Could not register: #{errors}")}
    end
  end

  def handle_event("ping", %{"id" => id}, socket) do
    endpoint = ChangeStream.get_endpoint!(id)
    started = System.monotonic_time(:millisecond)

    case ChangeStream.ping(endpoint) do
      {:ok, status} ->
        ms = System.monotonic_time(:millisecond) - started
        {:noreply, put_flash(socket, :info, "#{endpoint.url} answered #{status} in #{ms}ms")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Ping failed: #{describe(reason)}")}
    end
  end

  def handle_event("pause", %{"id" => id}, socket) do
    {:ok, _} = ChangeStream.pause(ChangeStream.get_endpoint!(id))

    {:noreply,
     socket |> put_flash(:info, "Paused. Events are retained for the endpoint.") |> load()}
  end

  def handle_event("resume", %{"id" => id}, socket) do
    {:ok, _} = ChangeStream.resume(ChangeStream.get_endpoint!(id))
    {:noreply, socket |> put_flash(:info, "Resumed.") |> load()}
  end

  def handle_event("retry", %{"id" => id}, socket) do
    endpoint = ChangeStream.get_endpoint!(id)

    flash =
      case ChangeStream.retry_now(endpoint) do
        :ok -> {:info, "Delivered pending events to #{endpoint.url}."}
        :skipped -> {:info, "Nothing pending for #{endpoint.url}."}
        {:error, reason} -> {:error, "Delivery failed: #{describe(reason)}"}
      end

    {kind, text} = flash
    {:noreply, socket |> put_flash(kind, text) |> load()}
  end

  def handle_event("backfill", %{"id" => id}, socket) do
    case ChangeStream.start_backfill(ChangeStream.get_endpoint!(id)) do
      :ok ->
        schedule_refresh()
        {:noreply, socket |> put_flash(:info, "Backfill started.") |> load()}

      {:error, :already_running} ->
        {:noreply, put_flash(socket, :error, "A backfill is already running for that endpoint.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    endpoint = ChangeStream.get_endpoint!(id)
    :ok = ChangeStream.delete_endpoint(endpoint)
    {:noreply, socket |> put_flash(:info, "Removed #{endpoint.url}.") |> load()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = load(socket)

    if Enum.any?(socket.assigns.endpoints, &(&1.endpoint.backfill_status == "running")),
      do: schedule_refresh()

    {:noreply, socket}
  end

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp load(socket) do
    endpoints = ChangeStream.list_endpoints()

    rows =
      Enum.map(endpoints, fn e ->
        %{endpoint: e, lag: ChangeStream.lag(e), gap?: ChangeStream.gap?(e)}
      end)

    failing = Enum.filter(endpoints, &(&1.status == "failing"))

    socket
    |> assign(:endpoints, rows)
    |> assign(:latest_event_id, ChangeStream.latest_event_id())
    |> assign(:enabled?, ChangeStream.enabled?())
    |> assign(:poll_seconds, ChangeStream.poll_seconds())
    |> assign(:plan, Backfill.plan())
    |> assign(:failing_banner, failing_banner(failing))
  end

  defp failing_banner([]), do: nil

  defp failing_banner(failing) do
    urls = Enum.map_join(failing, ", ", & &1.url)

    %{
      class: "alert-error",
      text:
        "#{length(failing)} endpoint(s) failing: #{urls}. Deliveries keep retrying hourly; " <>
          "fix the receiver, then Retry now."
    }
  end

  defp describe({:http, status, _body}), do: "HTTP #{status}"
  defp describe(reason), do: inspect(reason, limit: 60)

  defp status_badge("active"), do: "badge-success"
  defp status_badge("paused"), do: "badge-ghost"
  defp status_badge("failing"), do: "badge-error"

  defp backfill_badge("idle"), do: "badge-ghost"
  defp backfill_badge("running"), do: "badge-info"
  defp backfill_badge("done"), do: "badge-success"
  defp backfill_badge("failed"), do: "badge-error"

  defp ago(nil), do: "never"

  defp ago(%DateTime{} = at) do
    s = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      s < 60 -> "#{s}s ago"
      s < 3600 -> "#{div(s, 60)}m ago"
      s < 86_400 -> "#{div(s, 3600)}h ago"
      true -> "#{div(s, 86_400)}d ago"
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
          <h1 class="text-2xl font-semibold">Change stream</h1>
          <div class="flex items-center gap-3">
            <span class="text-sm opacity-70">
              <%= cond do %>
                <% @poll_seconds == 0 -> %>
                  worker disabled (CHANGE_STREAM_POLL_SECONDS=0)
                <% @enabled? -> %>
                  polling every {@poll_seconds}s · latest event #{@latest_event_id}
                <% true -> %>
                  idle — no endpoints registered
              <% end %>
            </span>
            <.link navigate={~p"/admin"} class="btn btn-sm btn-ghost">Fleet</.link>
            <button phx-click="refresh" class="btn btn-sm">Refresh</button>
          </div>
        </div>

        <div :if={@failing_banner} class={["alert mb-4", @failing_banner.class]}>
          <span>{@failing_banner.text}</span>
        </div>

        <%!-- The secret is shown exactly once; after that only the DB has it. --%>
        <div :if={@new_secret} class="alert alert-success mb-4 flex-col items-start gap-1">
          <div class="font-medium">Signing secret for {@new_secret.url}</div>
          <code class="text-xs break-all select-all" id="new-signing-secret">{@new_secret.secret}</code>
          <div class="text-xs opacity-70">
            Copy it now — it is not shown again. Verify <code>x-poet-signature</code>
            as HMAC-SHA256 over <code>"&lt;t&gt;.&lt;raw body&gt;"</code>.
          </div>
          <button phx-click="dismiss_secret" class="btn btn-xs">Dismiss</button>
        </div>

        <div class="overflow-x-auto mb-8">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Endpoint</th>
                <th>Status</th>
                <th>Lag</th>
                <th>Failures</th>
                <th>Last success</th>
                <th>Last failure</th>
                <th>Backfill</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@endpoints == []}>
                <td colspan="8" class="opacity-60">No endpoints registered.</td>
              </tr>
              <tr :for={row <- @endpoints} class={row.endpoint.status == "failing" && "bg-error/5"}>
                <td class="max-w-xs truncate" title={row.endpoint.url}>{row.endpoint.url}</td>
                <td>
                  <span class={["badge badge-sm", status_badge(row.endpoint.status)]}>
                    {row.endpoint.status}
                  </span>
                </td>
                <td class="tabular-nums">
                  {row.lag}
                  <span
                    :if={row.gap?}
                    class="badge badge-warning badge-xs"
                    title="Events were pruned before this endpoint acknowledged them — run a backfill"
                  >
                    gap
                  </span>
                </td>
                <td class="tabular-nums">
                  {row.endpoint.consecutive_failures}
                  <span :if={row.endpoint.next_attempt_at} class="text-xs opacity-50">
                    next {ago(row.endpoint.next_attempt_at) |> String.replace(" ago", "")}
                  </span>
                </td>
                <td>{ago(row.endpoint.last_success_at)}</td>
                <td>
                  {ago(row.endpoint.last_failure_at)}
                  <div
                    :if={row.endpoint.last_error}
                    class="text-xs opacity-60 max-w-xs truncate"
                    title={row.endpoint.last_error}
                  >
                    {row.endpoint.last_status_code && "HTTP #{row.endpoint.last_status_code} · "}{row.endpoint.last_error}
                  </div>
                </td>
                <td>
                  <span class={["badge badge-sm", backfill_badge(row.endpoint.backfill_status)]}>
                    {row.endpoint.backfill_status}
                  </span>
                  <div :if={row.endpoint.backfill_status == "running"} class="text-xs opacity-60">
                    {row.endpoint.backfill_progress["entity"]}
                    {row.endpoint.backfill_progress["sent"]}/{row.endpoint.backfill_progress["total"]}
                  </div>
                  <div
                    :if={row.endpoint.backfill_status == "failed"}
                    class="text-xs opacity-60 max-w-xs truncate"
                    title={row.endpoint.backfill_error}
                  >
                    {row.endpoint.backfill_error}
                  </div>
                  <div :if={row.endpoint.backfilled_at} class="text-xs opacity-60">
                    {ago(row.endpoint.backfilled_at)}
                  </div>
                </td>
                <td>
                  <div class="flex flex-wrap gap-1">
                    <button phx-click="ping" phx-value-id={row.endpoint.id} class="btn btn-xs">Ping</button>
                    <button
                      :if={row.endpoint.status != "paused"}
                      phx-click="pause"
                      phx-value-id={row.endpoint.id}
                      class="btn btn-xs"
                    >
                      Pause
                    </button>
                    <button
                      :if={row.endpoint.status == "paused"}
                      phx-click="resume"
                      phx-value-id={row.endpoint.id}
                      class="btn btn-xs"
                    >
                      Resume
                    </button>
                    <button phx-click="retry" phx-value-id={row.endpoint.id} class="btn btn-xs">
                      Retry now
                    </button>
                    <button
                      phx-click="backfill"
                      phx-value-id={row.endpoint.id}
                      class="btn btn-xs btn-outline"
                      data-confirm={"Send the entire database (#{Enum.sum(Enum.map(@plan, & &1.total))} records) to #{row.endpoint.url}?"}
                    >
                      Backfill
                    </button>
                    <button
                      phx-click="delete"
                      phx-value-id={row.endpoint.id}
                      class="btn btn-xs btn-error btn-outline"
                      data-confirm={"Remove #{row.endpoint.url}? It stops receiving events immediately."}
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <h2 class="text-lg font-semibold mb-2">Register an endpoint</h2>
        <form phx-submit="register" class="flex flex-wrap items-end gap-2 mb-8">
          <label class="form-control">
            <span class="label-text text-xs">URL</span>
            <input
              type="url"
              name="url"
              placeholder="https://agent.example.com/hooks/poet"
              required
              class="input input-bordered input-sm w-96"
            />
          </label>
          <label class="form-control">
            <span class="label-text text-xs">Bearer token the receiver expects</span>
            <input
              type="text"
              name="auth_token"
              autocomplete="off"
              required
              class="input input-bordered input-sm w-72"
            />
          </label>
          <button type="submit" class="btn btn-sm btn-primary">Register</button>
        </form>

        <details class="mb-8">
          <summary class="cursor-pointer text-sm opacity-70">
            What a backfill sends ({Enum.sum(Enum.map(@plan, & &1.total))} records across {length(
              @plan
            )} tables)
          </summary>
          <table class="table table-xs mt-2 max-w-md">
            <tbody>
              <tr :for={p <- @plan}>
                <td>{p.entity}</td>
                <td class="tabular-nums">{p.total}</td>
              </tr>
            </tbody>
          </table>
        </details>
      </div>
    </Layouts.app>
    """
  end
end
