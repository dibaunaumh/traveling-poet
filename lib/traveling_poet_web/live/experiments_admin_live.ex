defmodule TravelingPoetWeb.ExperimentsAdminLive do
  @moduledoc """
  The admins' experiments: blind writing tests (`Evals.BlindTests`), judged
  one day at a time and saved on the server with every tap, so a test can be
  judged on a phone. Pages show by letter only; which candidate wrote which
  comes out only through Reveal, once every day has a best page.
  """

  use TravelingPoetWeb, :live_view

  import TravelingPoetWeb.NotebookComponents, only: [raw_markdown: 1]

  alias TravelingPoet.Evals.BlindTests

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Admin: experiments", revealed: false)}
  end

  @impl true
  def handle_params(%{"name" => name} = params, _uri, socket) do
    case BlindTests.get(name) do
      nil ->
        {:noreply,
         socket |> put_flash(:error, "No such test") |> push_navigate(to: ~p"/admin/experiments")}

      test ->
        days = BlindTests.days(test)
        index = params |> Map.get("day", "1") |> parse_index(length(days))

        {:noreply,
         assign(socket,
           test: test,
           days: days,
           index: index,
           day: Enum.at(days, index),
           tests: nil
         )
         |> assign_vote()}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, test: nil, tests: BlindTests.list())}
  end

  defp parse_index(raw, count) do
    case Integer.parse(raw) do
      {n, ""} -> n |> max(1) |> min(max(count, 1)) |> Kernel.-(1)
      _ -> 0
    end
  end

  @impl true
  def handle_event("best", %{"letter" => letter}, socket) do
    save(socket, BlindTests.set_best(socket.assigns.test, socket.assigns.day.id, letter))
  end

  def handle_event("mark", %{"letter" => letter, "mark" => mark}, socket) do
    save(
      socket,
      BlindTests.toggle_mark(socket.assigns.test, socket.assigns.day.id, letter, mark)
    )
  end

  def handle_event("go", %{"day" => day}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/admin/experiments/#{socket.assigns.test.name}?day=#{day}")}
  end

  def handle_event("reveal", _params, socket), do: {:noreply, assign(socket, revealed: true)}

  defp save(socket, {:ok, test}), do: {:noreply, socket |> assign(test: test) |> assign_vote()}

  defp save(socket, {:error, _}),
    do: {:noreply, put_flash(socket, :error, "That vote was not saved")}

  defp assign_vote(socket),
    do: assign(socket, :vote, BlindTests.vote(socket.assigns.test, socket.assigns.day.id))

  defp judged?(test, day_id), do: BlindTests.vote(test, day_id)["best"] != nil

  defp mark_label("publishable"), do: "Publishable"
  defp mark_label("gibberish"), do: "Gibberish"
  defp mark_label("preachy"), do: "Preachy"

  defp num(nil, _), do: "-"
  defp num(x, 0), do: "#{round(x)}"
  defp num(x, d), do: :erlang.float_to_binary(x * 1.0, decimals: d)

  defp usd(nil), do: "-"
  defp usd(x), do: "$" <> :erlang.float_to_binary(x * 1.0, decimals: 4)

  @impl true
  def render(%{test: nil} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={assigns[:current_user]}
      credits_low={assigns[:credits_low]}
    >
      <div class="mx-auto max-w-3xl py-8 space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h1 class="text-2xl font-semibold">Experiments</h1>
          <.link navigate={~p"/admin"} class="btn btn-sm btn-ghost">Fleet</.link>
        </div>
        <p :if={@tests == []} class="text-sm opacity-60">No blind tests loaded.</p>
        <ul class="space-y-2" id="blind-tests">
          <li :for={t <- @tests} id={"blind-test-#{t.id}"}>
            <.link
              navigate={~p"/admin/experiments/#{t.name}"}
              class="block rounded-box border border-base-300 p-4 hover:bg-base-200"
            >
              <div class="font-semibold">{t.title}</div>
              <div class="text-sm opacity-70">
                Blind writing test, {BlindTests.judged(t)} of {length(t.manifest["days"])} days judged
              </div>
            </.link>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={assigns[:current_user]}
      credits_low={assigns[:credits_low]}
    >
      <div class="mx-auto max-w-6xl py-4 space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div>
            <h1 class="text-xl font-semibold">{@test.title}</h1>
            <p class="text-sm opacity-70" id="blind-progress">
              {BlindTests.judged(@test)} of {length(@days)} days judged
            </p>
          </div>
          <.link navigate={~p"/admin/experiments"} class="btn btn-sm btn-ghost">All tests</.link>
        </div>

        <p class="text-sm opacity-70">
          Pick the better page of each day; mark any page publishable, gibberish or preachy.
          Every tap is saved. Drawings are left out.
        </p>

        <form phx-change="go" class="flex items-center gap-2">
          <.link
            :if={@index > 0}
            patch={~p"/admin/experiments/#{@test.name}?day=#{@index}"}
            class="btn btn-sm"
            id="prev-day"
          >
            Previous
          </.link>
          <select name="day" class="select select-sm flex-1 min-w-0" aria-label="Day">
            <option
              :for={{d, i} <- Enum.with_index(@days, 1)}
              value={i}
              selected={i == @index + 1}
            >
              {if judged?(@test, d.id), do: "Judged", else: "Open"} · {i}. {d.poet}, {d.date}
            </option>
          </select>
          <.link
            :if={@index < length(@days) - 1}
            patch={~p"/admin/experiments/#{@test.name}?day=#{@index + 2}"}
            class="btn btn-sm btn-primary"
            id="next-day"
          >
            Next
          </.link>
        </form>

        <div class="text-sm opacity-80">
          {@day.poet} · {@day.date} · {if @day.language == "he", do: "Hebrew", else: "English"}{if @day.excursion,
            do: " · excursion"}
        </div>

        <div class="grid gap-4 md:grid-cols-2">
          <article
            :for={p <- @day.pages}
            id={"page-#{p.letter}"}
            class="rounded-box border border-base-300 bg-base-100 p-4 space-y-3 min-w-0"
          >
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-2xl font-semibold font-mono">{p.letter}</span>
              <button
                :if={!p[:missing]}
                phx-click="best"
                phx-value-letter={p.letter}
                class={[
                  "btn btn-sm",
                  if(@vote["best"] == p.letter, do: "btn-primary", else: "btn-outline")
                ]}
                id={"best-#{p.letter}"}
              >
                {if @vote["best"] == p.letter, do: "Best", else: "Pick as best"}
              </button>
              <button
                :for={mark <- BlindTests.marks()}
                :if={!p[:missing]}
                phx-click="mark"
                phx-value-letter={p.letter}
                phx-value-mark={mark}
                class={[
                  "btn btn-xs",
                  if(p.letter in @vote[mark], do: "btn-secondary", else: "btn-ghost")
                ]}
                id={"mark-#{mark}-#{p.letter}"}
              >
                {mark_label(mark)}
              </button>
            </div>

            <p :if={p[:missing]} class="text-sm opacity-60">Not written: {p.missing}</p>

            <div :if={!p[:missing]} dir="auto" class="space-y-3 min-w-0 [overflow-wrap:anywhere]">
              <h2 class="text-lg font-semibold" dir="auto">{p.title}</h2>
              <p :if={p.teaser not in [nil, ""]} class="italic opacity-80" dir="auto">{p.teaser}</p>
              <section :for={s <- p.sections} class="space-y-1" dir="auto">
                <div class="text-xs uppercase tracking-wide opacity-50">{s["kind"]}</div>
                <h3 :if={s["title"] not in [nil, ""]} class="font-semibold">{s["title"]}</h3>
                <div class={[
                  "prose prose-sm max-w-none",
                  s["kind"] == "poem" && "whitespace-pre-line"
                ]}>
                  {raw_markdown(s["body"])}
                </div>
              </section>
              <ul :if={p.notes != []} class="text-xs opacity-60 flex flex-wrap gap-x-3" dir="ltr">
                <li :for={n <- p.notes}>{n}</li>
              </ul>
            </div>
          </article>
        </div>

        <div class="flex justify-end">
          <.link
            :if={@index < length(@days) - 1}
            patch={~p"/admin/experiments/#{@test.name}?day=#{@index + 2}"}
            class="btn btn-primary"
          >
            Next day
          </.link>
        </div>

        <section :if={BlindTests.judged(@test) == length(@days)} class="space-y-3" id="reveal">
          <button :if={!@revealed} phx-click="reveal" class="btn btn-primary" id="reveal-button">
            Reveal
          </button>
          <div :if={@revealed} class="overflow-x-auto">
            <table class="table table-sm" id="reveal-table">
              <thead>
                <tr>
                  <th>Who wrote it</th>
                  <th>Best</th>
                  <th>Publishable</th>
                  <th>Gibberish</th>
                  <th>Preachy</th>
                  <th>Broken sentences</th>
                  <th>Fluency</th>
                  <th>Words</th>
                  <th>Cost per page</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={r <- BlindTests.tally(@test)}>
                  <td>{r.model || r.id}</td>
                  <td>{r.wins} of {r.judged}</td>
                  <td>{r.publishable}</td>
                  <td>{r.gibberish}</td>
                  <td>{r.preachy}</td>
                  <td>{num(r.broken_sentences, 2)}</td>
                  <td>{num(r.fluency, 2)}</td>
                  <td>{num(r.words, 0)}</td>
                  <td>{usd(r.mean_cost)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
