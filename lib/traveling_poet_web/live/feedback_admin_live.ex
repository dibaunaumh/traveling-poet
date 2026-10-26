defmodule TravelingPoetWeb.FeedbackAdminLive do
  @moduledoc """
  What readers told us about the app (card-137): the messages from
  `/feedback`, newest first, each marked done once handled, and the answers
  to the recommend question with the score over the last 90 days. Every one
  of them also reached the admins on Telegram when it came in.
  """

  use TravelingPoetWeb, :live_view

  alias TravelingPoet.Feedback
  alias TravelingPoet.Feedback.NpsResponse

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Admin: feedback") |> assign(:show, "new") |> load()}
  end

  @impl true
  def handle_event("show", %{"show" => show}, socket) when show in ["new", "all"],
    do: {:noreply, socket |> assign(:show, show) |> load()}

  def handle_event("set_status", %{"id" => id, "status" => status}, socket) do
    with %{} = message <- Feedback.get_message(id) do
      Feedback.set_status(message, status)
    end

    {:noreply, load(socket)}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    status = if socket.assigns.show == "new", do: "new"

    socket
    |> assign(:messages, Feedback.list_messages(status: status))
    |> assign(:nps, Feedback.nps_summary(90))
    |> assign(:responses, Feedback.recent_responses(100))
  end

  defp kind_label("broken"), do: "Broken"
  defp kind_label("change"), do: "Change"
  defp kind_label("missing"), do: "Missing"
  defp kind_label(_), do: "Other"

  defp when_label(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  defp score_class(score) do
    case NpsResponse.bucket(score) do
      :promoter -> "badge badge-success"
      :passive -> "badge badge-ghost"
      :detractor -> "badge badge-error"
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
      <div class="mx-auto max-w-5xl py-8 space-y-8">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-semibold">Reader feedback</h1>
          <div class="flex items-center gap-2">
            <.link navigate={~p"/admin"} class="btn btn-sm btn-ghost">Fleet</.link>
            <button phx-click="refresh" class="btn btn-sm">Refresh</button>
          </div>
        </div>

        <section id="nps-summary">
          <h2 class="font-semibold mb-2">Would recommend, last 90 days</h2>
          <p :if={@nps.count == 0} class="text-sm opacity-60">No answers yet.</p>
          <div :if={@nps.count > 0} class="flex flex-wrap items-baseline gap-6">
            <div>
              <span class="text-3xl font-semibold font-mono">{@nps.score}</span>
              <span class="text-sm opacity-60">NPS</span>
            </div>
            <div class="text-sm opacity-80">
              {@nps.count} {if @nps.count == 1, do: "reader", else: "readers"}: {@nps.promoters} promoters, {@nps.passives} passives, {@nps.detractors} detractors
            </div>
          </div>
          <p class="text-xs opacity-60 mt-2">
            Each reader's latest answer counts once. NPS is percent promoters (9-10) minus percent detractors (0-6).
          </p>
        </section>

        <section>
          <div class="flex items-center justify-between mb-2">
            <h2 class="font-semibold">Messages</h2>
            <div class="flex gap-1">
              <button
                :for={{value, label} <- [{"new", "New"}, {"all", "All"}]}
                phx-click="show"
                phx-value-show={value}
                class={["btn btn-xs", if(@show == value, do: "btn-primary", else: "btn-ghost")]}
              >
                {label}
              </button>
            </div>
          </div>
          <p :if={@messages == []} class="text-sm opacity-60">Nothing here.</p>
          <table :if={@messages != []} class="table table-sm" id="feedback-messages">
            <thead>
              <tr>
                <th>When</th>
                <th>From</th>
                <th>Kind</th>
                <th>Message</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={m <- @messages}
                id={"feedback-#{m.id}"}
                class={m.status == "done" && "opacity-50"}
              >
                <td class="whitespace-nowrap font-mono text-xs">{when_label(m.inserted_at)}</td>
                <td class="text-xs">
                  <%= if m.user do %>
                    {m.user.name || "(no name)"}<br />
                    <span class="opacity-60">{m.user.email}</span>
                  <% else %>
                    <a href={"mailto:#{m.email}"} class="link">{m.email}</a><br />
                    <span class="opacity-60">signed out</span>
                  <% end %>
                </td>
                <td class="text-xs">{kind_label(m.kind)}</td>
                <td class="text-sm">
                  <p class="whitespace-pre-line">{m.body}</p>
                  <p :if={m.page || m.client} class="text-xs opacity-50 mt-1">
                    {[m.page, m.client] |> Enum.reject(&is_nil/1) |> Enum.join(", ")}
                  </p>
                </td>
                <td>
                  <button
                    phx-click="set_status"
                    phx-value-id={m.id}
                    phx-value-status={if m.status == "done", do: "new", else: "done"}
                    class="btn btn-xs btn-ghost"
                  >
                    {if m.status == "done", do: "Reopen", else: "Done"}
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section>
          <h2 class="font-semibold mb-2">Recommend answers</h2>
          <p :if={@responses == []} class="text-sm opacity-60">No answers yet.</p>
          <table :if={@responses != []} class="table table-sm" id="nps-responses">
            <thead>
              <tr>
                <th>When</th>
                <th>Reader</th>
                <th>Score</th>
                <th>Comment</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={r <- @responses}>
                <td class="whitespace-nowrap font-mono text-xs">{when_label(r.inserted_at)}</td>
                <td class="text-xs">{r.user.name || r.user.email}</td>
                <td><span class={score_class(r.score)}>{r.score}</span></td>
                <td class="text-sm whitespace-pre-line">{r.comment}</td>
              </tr>
            </tbody>
          </table>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
