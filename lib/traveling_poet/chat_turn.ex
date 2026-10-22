defmodule TravelingPoet.ChatTurn do
  @moduledoc """
  Sees a reader's web chat turn through on the server.

  The journal page used to be the only thing listening for the poet's reply:
  the chat panel saved it when the stream finished, and the page held the
  sprite awake only while the reader was active. A reader who asked for
  something long and closed the app lost the answer twice over: the sprite
  paused mid-turn, and nothing was left to save the reply. On 2026-10-19 two
  new readers asked for a two-week itinerary and a piece on a city, put the
  phone down, and never heard back; both poets froze halfway through their
  research.

  `watch/1` starts one of these per reader when a message goes out (or tells
  the running one that another went out). It listens on the reader's gateway
  socket, holds the sprite awake until the turn ends (at most
  `max_turn_ms/0`), and saves the reply with
  `Chat.create_agent_message_once/1`; an open chat panel saves the same reply
  and one of the two wins. When no journal page is open for the reader
  (`reader_present?/1`), it broadcasts `{:poet_replied, user_id, message_id}`
  on `"chat"` so the notifiers can tell them.
  """

  use GenServer, restart: :temporary

  require Logger

  alias TravelingPoet.{AgentSession, Chat, GatewaySocket, GatewaySocketSupervisor, SpriteHold}

  @max_turn_ms 30 * 60 * 1000
  @hold_expire "5m"
  @hold_refresh_ms 60 * 1000

  def max_turn_ms, do: @max_turn_ms

  @doc """
  Watches the turn a reader's message just started. Call it before sending,
  so the reply cannot finish before anyone is listening.

  Options (for tests): `:socket`, the gateway socket pid to listen on.
  """
  def watch(%{id: user_id} = user, opts \\ []) do
    case whereis(user_id) do
      nil ->
        case DynamicSupervisor.start_child(
               TravelingPoet.ChatTurnSupervisor,
               {__MODULE__, {user, opts}}
             ) do
          {:error, {:already_started, pid}} -> another(pid)
          other -> other
        end

      pid ->
        another(pid)
    end
  end

  def whereis(user_id) do
    case Registry.lookup(TravelingPoet.GatewayRegistry, {__MODULE__, user_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Marks the calling process (a journal page) as the reader looking at their chat."
  def reader_present(user_id) do
    Registry.register(TravelingPoet.ReaderRegistry, user_id, nil)
  end

  @doc "Whether a journal page is open for this reader right now."
  def reader_present?(user_id) do
    Registry.lookup(TravelingPoet.ReaderRegistry, user_id) != []
  end

  defp another(pid) do
    GenServer.cast(pid, :another)
    {:ok, pid}
  end

  def start_link({user, opts}) do
    GenServer.start_link(__MODULE__, {user, opts},
      name: {:via, Registry, {TravelingPoet.GatewayRegistry, {__MODULE__, user.id}}}
    )
  end

  @impl true
  def init({user, opts}) do
    case Keyword.get_lazy(opts, :socket, fn -> connect(user) end) do
      pid when is_pid(pid) ->
        GatewaySocket.subscribe(pid)
        hold = SpriteHold.task_name("reply")
        put_hold(user, hold)
        Process.send_after(self(), :refresh_hold, @hold_refresh_ms)
        Process.send_after(self(), :give_up, @max_turn_ms)

        {:ok, %{user: user, socket: pid, hold: hold, pending: 1, text: ""}}

      _ ->
        :ignore
    end
  end

  defp connect(user) do
    case GatewaySocketSupervisor.ensure_connected(user) do
      {:ok, pid} -> pid
      _ -> nil
    end
  end

  @impl true
  def handle_cast(:another, state), do: {:noreply, %{state | pending: state.pending + 1}}

  @impl true
  def handle_info({:gateway_event, {:text_delta, delta}}, state),
    do: {:noreply, %{state | text: state.text <> delta}}

  def handle_info({:gateway_event, {:text_replace, text}}, state),
    do: {:noreply, %{state | text: text}}

  def handle_info({:gateway_event, {:done, response_id}}, state) do
    if AgentSession.housekeeping_reply?(String.trim(state.text)) do
      {:noreply, %{state | text: ""}}
    else
      save(state, response_id)
      finished(%{state | text: ""})
    end
  end

  # The gateway turned the message away (another turn was running): it
  # started nothing to wait for. Any other error ends the turn; the open
  # panel shows it.
  def handle_info({:gateway_event, {:error, reason}}, state) do
    if is_binary(reason) and String.contains?(reason, "Chat error") do
      finished(state)
    else
      {:stop, :normal, state}
    end
  end

  def handle_info({:gateway_event, _}, state), do: {:noreply, state}

  def handle_info(:refresh_hold, state) do
    put_hold(state.user, state.hold)
    Process.send_after(self(), :refresh_hold, @hold_refresh_ms)
    {:noreply, state}
  end

  def handle_info(:give_up, state) do
    Logger.warning("ChatTurn: no reply for user #{state.user.id} within the turn limit")
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    GatewaySocket.unsubscribe(state.socket)
    user = state.user
    Task.start(fn -> SpriteHold.delete(user.sprite_name, state.hold) end)
    :ok
  end

  defp finished(%{pending: pending} = state) when pending > 1,
    do: {:noreply, %{state | pending: pending - 1}}

  defp finished(state), do: {:stop, :normal, state}

  defp save(%{text: ""}, _response_id), do: :ok

  defp save(%{user: user, text: text}, response_id) do
    case Chat.create_agent_message_once(%{
           user_id: user.id,
           content: text,
           response_id: response_id
         }) do
      {:ok, %Chat.ChatMessage{} = message} ->
        unless reader_present?(user.id) do
          Phoenix.PubSub.broadcast(
            TravelingPoet.PubSub,
            "chat",
            {:poet_replied, user.id, message.id}
          )
        end

      _ ->
        :ok
    end
  end

  defp put_hold(user, hold) do
    Task.start(fn -> SpriteHold.put(user.sprite_name, hold, @hold_expire) end)
  end
end
