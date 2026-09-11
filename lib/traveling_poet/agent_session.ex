defmodule TravelingPoet.AgentSession do
  @moduledoc """
  Headless agent exchange: wake the sprite (the inbound WebSocket connect does
  it), send a message, hold the sprite awake through the turn with a Sprites
  task (see `SpriteHold`), collect the streamed reply until :done, and persist
  both sides to Chat. Used by the Telegram poller and the DailyJourneyScheduler —
  the same shape alice-in-goals' TpmSyncScheduler proved out.
  """

  require Logger

  alias TravelingPoet.{Chat, GatewaySocket, GatewaySocketSupervisor, SpriteHold}

  @default_reply_timeout_ms 5 * 60 * 1000

  @doc """
  Runs one exchange. Options:

    * `:channel` — chat channel to persist under ("system" | "telegram"), default "system"
    * `:reply_timeout_ms` — how long to wait for :done (default 5 min)

  The sprite is held awake for exactly as long as the turn runs (bounded by
  `:reply_timeout_ms`) and released when it finishes.
    * `:persist` — persist both sides to Chat (default true)

  Returns `{:ok, reply_text}` when the agent finished its turn (`:done`),
  `{:timeout, partial_text}` when it went silent for `:reply_timeout_ms`
  before finishing, or `{:error, reason}`.

  A timeout is NOT a success even when `partial_text` is non-empty: the agent
  may have narrated its way through half the ritual and then stalled, leaving
  its work unpublished. Callers must treat `{:timeout, _}` as a failed turn.
  """
  def run(user, message, opts \\ []) do
    channel = Keyword.get(opts, :channel, "system")
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

        result =
          SpriteHold.with_hold(user.sprite_name, "turn", fn ->
            collect_reply(user, "", timeout, persist?, channel)
          end)

        GatewaySocket.unsubscribe(pid)
        result

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

        {:ok, content}

      {:gateway_event, _other} ->
        collect_reply(user, acc, timeout, persist?, channel)
    after
      timeout ->
        partial = String.trim(acc)

        Logger.warning(
          "AgentSession: no agent reply within timeout for user #{user.id} " <>
            "(#{String.length(partial)} chars of partial text)"
        )

        {:timeout, partial}
    end
  end
end
