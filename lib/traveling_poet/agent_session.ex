defmodule TravelingPoet.AgentSession do
  @moduledoc """
  Headless agent exchange: wake the sprite (the inbound WebSocket connect does
  it), send a message, hold the sprite awake through the turn with blocking
  on-sprite execs, collect the streamed reply until :done, and persist both
  sides to Chat. Used by the chat channels (Messaging.Inbound) and the
  DailyJourneyScheduler —
  the same shape alice-in-goals' TpmSyncScheduler proved out.
  """

  require Logger

  alias TravelingPoet.{Chat, GatewaySocket, GatewaySocketSupervisor, SpritesClient}

  @default_reply_timeout_ms 5 * 60 * 1000
  # ~90s per blocking exec stays inside SpritesClient's 120s window
  @hold_awake_exec_seconds 90

  @doc """
  Runs one exchange. Options:

    * `:channel` — chat channel to persist under ("system" | "telegram" |
      "whatsapp"), default "system"
    * `:hold_awake_rounds` — how many ~90s keepalive execs to chain (default 3)
    * `:reply_timeout_ms` — how long to wait for :done (default 5 min)
    * `:persist` — persist both sides to Chat (default true)

  Returns `{:ok, reply_text}` (may be `""` on timeout) or `{:error, reason}`.
  """
  def run(user, message, opts \\ []) do
    channel = Keyword.get(opts, :channel, "system")
    rounds = Keyword.get(opts, :hold_awake_rounds, 3)
    timeout = Keyword.get(opts, :reply_timeout_ms, @default_reply_timeout_ms)
    persist? = Keyword.get(opts, :persist, true)

    case GatewaySocketSupervisor.ensure_connected(user, attempts: 6) do
      {:ok, pid} ->
        GatewaySocket.subscribe(pid)
        GatewaySocket.send_message(pid, message)

        if persist? do
          Chat.create_message(%{
            user_id: user.id,
            role: "user",
            content: message,
            channel: channel
          })
        end

        # Sibling task keeps the sprite awake while this process waits.
        Task.start(fn -> hold_awake(user.sprite_name, rounds) end)

        reply = collect_reply(user, "", timeout, persist?, channel)
        GatewaySocket.unsubscribe(pid)
        {:ok, reply}

      err ->
        Logger.warning(
          "AgentSession: could not connect gateway for user #{user.id}: #{inspect(err)}"
        )

        {:error, err}
    end
  rescue
    e ->
      Logger.warning(
        "AgentSession: exchange for user #{user.id} crashed: #{Exception.message(e)}"
      )

      {:error, e}
  end

  defp collect_reply(user, acc, timeout, persist?, channel) do
    receive do
      {:gateway_event, {:text_delta, delta}} ->
        collect_reply(user, acc <> delta, timeout, persist?, channel)

      {:gateway_event, {:text_replace, text}} ->
        collect_reply(user, text, timeout, persist?, channel)

      {:gateway_event, {:done, response_id}} ->
        content = String.trim(acc)

        if persist? and content != "" and
             not Chat.recent_agent_message_exists?(user.id, content) do
          Chat.create_message(%{
            user_id: user.id,
            role: "agent",
            content: content,
            response_id: response_id,
            channel: channel
          })
        end

        content

      {:gateway_event, _other} ->
        collect_reply(user, acc, timeout, persist?, channel)
    after
      timeout ->
        Logger.warning("AgentSession: no agent reply within timeout for user #{user.id}")
        String.trim(acc)
    end
  end

  def hold_awake(nil, _rounds), do: :ok
  def hold_awake(_sprite_name, 0), do: :ok

  def hold_awake(sprite_name, rounds) do
    SpritesClient.exec(
      sprite_name,
      "for i in $(seq 1 #{@hold_awake_exec_seconds}); do sleep 1; done; echo held"
    )

    hold_awake(sprite_name, rounds - 1)
  end
end
