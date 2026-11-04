defmodule TravelingPoet.AiC.PubSubTap do
  @moduledoc """
  Forwards the global PubSub broadcasts that no explicit tap covers to AiC:
  `journal:published`, `asks`, `admin_events`, `credits:low`. A GenServer so
  a crash here never reaches the broadcaster. No-op when AiC is not configured.
  """

  use GenServer
  require Logger

  alias TravelingPoet.AiC

  @topics ~w(journal:published asks admin_events credits:low)

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if AliceInContext.enabled?() do
      Enum.each(@topics, &Phoenix.PubSub.subscribe(TravelingPoet.PubSub, &1))
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info({:journal_published, _poet_id, entry_id}, state) do
    safely(fn ->
      case TravelingPoet.Repo.get(TravelingPoet.Journal.Entry, entry_id) do
        nil -> :ok
        entry -> AiC.journal_published(entry)
      end
    end)

    {:noreply, state}
  end

  def handle_info({:reader_asked, user_id, ask_id}, state) do
    safely(fn ->
      case TravelingPoet.Repo.get(TravelingPoet.Asks.Ask, ask_id) do
        nil -> :ok
        ask -> AiC.poet_asked(%{id: ask.poet_id, user_id: user_id}, ask.question)
      end
    end)

    {:noreply, state}
  end

  def handle_info({:nps_answered, _response_id}, state) do
    # the score itself is recorded by Feedback.record_score's own tap
    {:noreply, state}
  end

  def handle_info({:credits_low, user_id}, state) do
    AiC.emit(%{type: "metric", verb: "credits_low", actor: AiC.reader_party(user_id), privacy: "internal",
               hints: %{space: "organization", address: "Serve/outer/Users/user-#{user_id}/credits"}})
    {:noreply, state}
  end

  def handle_info(event, state) when is_tuple(event) and is_atom(elem(event, 0)) do
    name = event |> elem(0) |> to_string()

    AiC.emit(%{type: "activity", verb: name, actor: AiC.system_party("app"), privacy: "internal",
               hints: %{space: "organization", address: "Operate/inner/App/events/#{name}"}})

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.debug("AiC.PubSubTap: #{inspect(e)}")
  end
end
