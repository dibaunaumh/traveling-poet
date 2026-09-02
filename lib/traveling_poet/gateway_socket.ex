defmodule TravelingPoet.GatewaySocket do
  @moduledoc """
  WebSocket client for a user's OpenClaw gateway.
  Handles Ed25519 device identity auth, chat messages, and streaming events.
  """

  # :temporary — never restarted by GatewaySocketSupervisor. Sockets are started on
  # demand by `GatewaySocketSupervisor.ensure_connected/1` and must be able to go
  # away for good once idle: a held-open WebSocket into the sprite is precisely what
  # keeps the sprite from suspending (and billing 24/7), so an idle socket that gets
  # resurrected by its supervisor — the previous :permanent default — pinned every
  # sprite awake forever.
  use WebSockex, restart: :temporary

  require Logger

  # Close the socket after this long with no subscribers. Without an open socket the
  # sprite suspends ~20s later; a socket left open with nobody listening is pure cost.
  @idle_timeout_ms 5 * 60 * 1000
  # Give up reconnecting after this many consecutive failures (reset on a successful
  # connect). Stops an endless tight reconnect loop when the target is permanently
  # gone — e.g. the user (and their sprite) was deleted but a dashboard LiveView is
  # still holding the socket, which otherwise reconnects every ~55ms forever on 302.
  @max_reconnect_attempts 8
  @reconnect_backoff_cap_ms 30_000
  @default_session_key "agent:main:main"
  @scopes [
    "operator.admin",
    "operator.read",
    "operator.write",
    "operator.approvals",
    "operator.pairing"
  ]

  # -- Public API --

  def start_link(opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    sprite_url = Keyword.fetch!(opts, :sprite_url)
    gateway_token = Keyword.fetch!(opts, :gateway_token)
    sprite_name = Keyword.fetch!(opts, :sprite_name)
    device_keys = Keyword.fetch!(opts, :device_keys)

    ws_url =
      sprite_url
      |> String.replace("https://", "wss://")
      |> String.replace("http://", "ws://")
      |> then(&(&1 <> "/ws"))

    {pub, priv} = device_keys
    device_id = :crypto.hash(:sha256, pub) |> Base.encode16(case: :lower)

    state = %{
      user_id: user_id,
      sprite_url: sprite_url,
      sprite_name: sprite_name,
      gateway_token: gateway_token,
      device_id: device_id,
      device_public_key: pub,
      device_private_key: priv,
      session_key: @default_session_key,
      status: :connecting,
      subscribers: MapSet.new(),
      pending_requests: %{},
      message_queue: [],
      idle_timer: nil,
      recover_stream: false,
      reconnect_attempts: 0
    }

    # Origin header required for webchat mode to pass allowedOrigins check
    origin =
      sprite_url
      |> URI.parse()
      |> then(fn uri ->
        "#{uri.scheme}://#{uri.host}#{if uri.port && uri.port not in [80, 443], do: ":#{uri.port}", else: ""}"
      end)

    name = via_tuple(user_id)

    WebSockex.start_link(ws_url, __MODULE__, state,
      name: name,
      extra_headers: [{"Origin", origin}]
    )
  end

  def send_message(pid, text) do
    WebSockex.cast(pid, {:send_message, text})
  end

  def subscribe(pid) do
    WebSockex.cast(pid, {:subscribe, self()})
  end

  def unsubscribe(pid) do
    WebSockex.cast(pid, {:unsubscribe, self()})
  end

  def via_tuple(user_id) do
    {:via, Registry, {TravelingPoet.GatewayRegistry, user_id}}
  end

  def whereis(user_id) do
    case Registry.lookup(TravelingPoet.GatewayRegistry, user_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc "Generate an Ed25519 key pair. Returns {public_key, private_key} as raw bytes."
  def generate_device_keys do
    :crypto.generate_key(:eddsa, :ed25519)
  end

  @doc "Derive device ID (SHA-256 hex) from raw public key bytes."
  def device_id_from_public_key(pub) do
    :crypto.hash(:sha256, pub) |> Base.encode16(case: :lower)
  end

  # -- WebSockex Callbacks --

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("GatewaySocket connected for user #{state.user_id}")
    # (Re)arm the idle timer whenever a connection lands with nobody subscribed —
    # covers a fresh socket whose caller never subscribes and a reconnect after the
    # subscribers already dropped. Subscribing cancels it again.
    state = maybe_start_idle_timer(%{state | status: :connected, reconnect_attempts: 0})
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, parsed} ->
        handle_gateway_frame(parsed, state)

      {:error, _} ->
        Logger.warning("GatewaySocket: unparseable frame: #{String.slice(msg, 0..200)}")
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_cast({:send_message, text}, state) do
    if state.status == :authenticated do
      req_id = generate_req_id()

      frame =
        Jason.encode!(%{
          type: "req",
          id: req_id,
          method: "chat.send",
          params: %{
            sessionKey: state.session_key,
            message: text,
            deliver: true,
            idempotencyKey: req_id
          }
        })

      # The idle timer is gated on subscribers only (see maybe_start_idle_timer);
      # cancelling it here without restarting it used to leave a subscriber-less
      # socket open forever.
      {:reply, {:text, frame},
       %{state | pending_requests: Map.put(state.pending_requests, req_id, :chat_send)}}
    else
      Logger.info("GatewaySocket: queuing message, status=#{state.status}")
      {:ok, %{state | message_queue: state.message_queue ++ [text]}}
    end
  end

  def handle_cast({:subscribe, pid}, state) do
    Process.monitor(pid)
    state = %{state | subscribers: MapSet.put(state.subscribers, pid)}
    state = reset_idle_timer(state)
    {:ok, state}
  end

  def handle_cast({:unsubscribe, pid}, state) do
    state = %{state | subscribers: MapSet.delete(state.subscribers, pid)}
    state = maybe_start_idle_timer(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = %{state | subscribers: MapSet.delete(state.subscribers, pid)}
    state = maybe_start_idle_timer(state)
    {:ok, state}
  end

  def handle_info(:idle_timeout, state) do
    if MapSet.size(state.subscribers) == 0 do
      Logger.info("GatewaySocket idle timeout for user #{state.user_id}, shutting down")
      {:close, state}
    else
      {:ok, state}
    end
  end

  def handle_info(:flush_queue, %{message_queue: [msg | rest]} = state) do
    req_id = generate_req_id()

    frame =
      Jason.encode!(%{
        type: "req",
        id: req_id,
        method: "chat.send",
        params: %{
          sessionKey: state.session_key,
          message: msg,
          deliver: true,
          idempotencyKey: req_id
        }
      })

    if rest != [], do: send(self(), :flush_queue)

    {:reply, {:text, frame},
     %{
       state
       | message_queue: rest,
         pending_requests: Map.put(state.pending_requests, req_id, :chat_send)
     }}
  end

  def handle_info(:flush_queue, state), do: {:ok, state}

  def handle_info(_msg, state), do: {:ok, state}

  # Our own idle close (`{:close, state}` from :idle_timeout) comes back through this
  # callback as `{:local, :normal}`. It is deliberate, not a drop: let the process
  # terminate (WebSockex exits :normal; :temporary means no restart) so the sprite can
  # suspend. Treating it as a drop reconnected within a second — and queued a
  # "please resend your last reply" prompt to the agent — which held every sprite
  # awake around the clock.
  @impl true
  def handle_disconnect(%{reason: {:local, :normal} = reason}, state) do
    Logger.info("GatewaySocket closed (idle) for user #{state.user_id}: #{inspect(reason)}")
    notify_subscribers(state, {:gateway_event, :disconnected})
    {:ok, %{state | status: :disconnected}}
  end

  def handle_disconnect(%{reason: reason}, state) do
    Logger.info("GatewaySocket disconnected for user #{state.user_id}: #{inspect(reason)}")
    notify_subscribers(state, {:gateway_event, :disconnected})
    attempts = state.reconnect_attempts + 1

    if attempts > @max_reconnect_attempts do
      # Target is persistently unreachable (e.g. user/sprite deleted → 302 forever).
      # Stop reconnecting rather than tight-looping; `{:ok, _}` lets WebSockex
      # terminate the process, and `ensure_connected/1` starts a fresh one on demand.
      Logger.warning(
        "GatewaySocket for user #{state.user_id} giving up after " <>
          "#{@max_reconnect_attempts} reconnect attempts: #{inspect(reason)}"
      )

      {:ok, %{state | status: :disconnected}}
    else
      # Exponential backoff with jitter, capped — a bare {:reconnect} retried every
      # ~55ms, flooding logs and the peer. Sleep here (this socket's own process is
      # otherwise idle while disconnected) before reconnecting.
      base = min(@reconnect_backoff_cap_ms, trunc(:math.pow(2, attempts) * 250))
      Process.sleep(base + :rand.uniform(250))
      was_streaming = map_size(state.pending_requests) > 0

      {:reconnect,
       %{
         state
         | status: :connecting,
           pending_requests: %{},
           recover_stream: was_streaming,
           reconnect_attempts: attempts
       }}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("GatewaySocket terminating for user #{state.user_id}: #{inspect(reason)}")
    :ok
  end

  # -- Private: frame handling --

  defp handle_gateway_frame(
         %{"type" => "event", "event" => "connect.challenge", "payload" => payload},
         state
       ) do
    nonce = payload["nonce"]
    Logger.info("GatewaySocket: connect.challenge for user #{state.user_id}")
    req_id = generate_req_id()
    signed_at_ms = System.system_time(:millisecond)

    # Build V3 pipe-delimited payload for device signature
    payload_str =
      [
        "v3",
        state.device_id,
        "gateway-client",
        "webchat",
        "operator",
        Enum.join(@scopes, ","),
        Integer.to_string(signed_at_ms),
        state.gateway_token,
        nonce,
        "server",
        ""
      ]
      |> Enum.join("|")

    signature =
      :crypto.sign(:eddsa, :none, payload_str, [state.device_private_key, :ed25519])
      |> Base.url_encode64(padding: false)

    frame =
      Jason.encode!(%{
        type: "req",
        id: req_id,
        method: "connect",
        params: %{
          minProtocol: 3,
          maxProtocol: 3,
          client: %{id: "gateway-client", version: "0.1.0", platform: "server", mode: "webchat"},
          auth: %{token: state.gateway_token, deviceToken: state.gateway_token},
          role: "operator",
          scopes: @scopes,
          caps: ["tool-events"],
          device: %{
            id: state.device_id,
            publicKey: Base.url_encode64(state.device_public_key, padding: false),
            signature: signature,
            signedAt: signed_at_ms,
            nonce: nonce
          }
        }
      })

    {:reply, {:text, frame},
     %{state | pending_requests: Map.put(state.pending_requests, req_id, :connect_auth)}}
  end

  # hello-ok response = authenticated (protocol 3 has no separate connect.ready event)
  defp handle_gateway_frame(
         %{"type" => "res", "ok" => true, "payload" => %{"type" => "hello-ok"} = payload},
         state
       ) do
    Logger.info("GatewaySocket: authenticated for user #{state.user_id}")

    # Extract session key from snapshot if available
    session_key =
      get_in(payload, ["snapshot", "sessionDefaults", "mainSessionKey"]) || @default_session_key

    state = %{state | status: :authenticated, session_key: session_key}
    notify_subscribers(state, {:gateway_event, :connected})

    cond do
      state.recover_stream ->
        Logger.info("GatewaySocket: recovering dropped stream for user #{state.user_id}")

        state = %{
          state
          | recover_stream: false,
            message_queue: [
              "I missed your last reply due to a connection issue. Can you please resend it?"
            ]
        }

        send(self(), :flush_queue)
        {:ok, state}

      state.message_queue != [] ->
        send(self(), :flush_queue)
        {:ok, state}

      true ->
        {:ok, state}
    end
  end

  defp handle_gateway_frame(
         %{"type" => "res", "id" => id, "ok" => false, "error" => error},
         state
       ) do
    {req_type, pending} = Map.pop(state.pending_requests, id)
    state = %{state | pending_requests: pending}
    error_msg = error["message"] || "Unknown error"

    case req_type do
      :connect_auth ->
        Logger.error("GatewaySocket: auth failed: #{error_msg}")

        notify_subscribers(
          state,
          {:gateway_event, {:error, "Authentication failed: #{error_msg}"}}
        )

      :chat_send ->
        Logger.error("GatewaySocket: chat.send error: #{error_msg}")
        notify_subscribers(state, {:gateway_event, {:error, error_msg}})

      _ ->
        Logger.warning("GatewaySocket: request #{id} failed: #{error_msg}")
    end

    {:ok, state}
  end

  defp handle_gateway_frame(
         %{"type" => "res", "id" => id, "ok" => true, "payload" => payload},
         state
       ) do
    {req_type, pending} = Map.pop(state.pending_requests, id)
    state = %{state | pending_requests: pending}

    case req_type do
      :chat_history ->
        # Extract last assistant message from chat history
        messages = payload["messages"] || []

        case Enum.find(Enum.reverse(messages), &(&1["role"] == "assistant")) do
          %{"content" => content} when is_list(content) ->
            extract_and_notify_text(content, state)

          _ ->
            Logger.warning("GatewaySocket: no assistant message in chat history")
        end

      _ ->
        :ok
    end

    {:ok, state}
  end

  defp handle_gateway_frame(%{"type" => "res", "id" => id, "ok" => true}, state) do
    {_req_type, pending} = Map.pop(state.pending_requests, id)
    {:ok, %{state | pending_requests: pending}}
  end

  # Agent assistant stream — text deltas (use only agent events, not chat events, to avoid duplication)
  defp handle_gateway_frame(
         %{
           "type" => "event",
           "event" => "agent",
           "payload" => %{"stream" => "assistant", "data" => %{"delta" => delta}}
         },
         state
       ) do
    notify_subscribers(state, {:gateway_event, {:text_delta, delta}})
    {:ok, state}
  end

  # Agent lifecycle — end of response (kept for logging, no longer used for done signal)
  defp handle_gateway_frame(
         %{
           "type" => "event",
           "event" => "agent",
           "payload" => %{
             "stream" => "lifecycle",
             "data" => %{"phase" => "end"}
           }
         },
         state
       ) do
    {:ok, state}
  end

  # Chat final — agent finished, fetch the response via chat.history
  defp handle_gateway_frame(
         %{
           "type" => "event",
           "event" => "chat",
           "payload" => %{"state" => "final", "sessionKey" => session_key}
         },
         state
       ) do
    req_id = generate_req_id()

    frame =
      Jason.encode!(%{
        type: "req",
        id: req_id,
        method: "chat.history",
        params: %{sessionKey: session_key, limit: 5}
      })

    Logger.info("GatewaySocket: chat final, fetching history")

    {:reply, {:text, frame},
     %{state | pending_requests: Map.put(state.pending_requests, req_id, :chat_history)}}
  end

  # Session message — response delivered via message tool (not streamed via agent events)
  defp handle_gateway_frame(
         %{
           "type" => "event",
           "event" => "session.message",
           "payload" => %{"message" => %{"role" => "assistant", "content" => content}}
         },
         state
       ) do
    text = extract_text(content)
    Logger.info("GatewaySocket: session.message received (#{String.length(text)} chars)")

    if text != "" do
      notify_subscribers(state, {:gateway_event, {:text_delta, text}})
      notify_subscribers(state, {:gateway_event, {:done, "session-message"}})
    end

    {:ok, state}
  end

  # Agent lifecycle error — rate limits, provider failures, etc.
  defp handle_gateway_frame(
         %{
           "type" => "event",
           "event" => "agent",
           "payload" => %{"stream" => "lifecycle", "data" => %{"phase" => "error"} = data}
         },
         state
       ) do
    error_msg = data["message"] || data["error"] || "Agent error"
    Logger.error("GatewaySocket: agent lifecycle error: #{error_msg}")
    notify_subscribers(state, {:gateway_event, {:error, error_msg}})
    {:ok, state}
  end

  # Chat session ended in error state
  defp handle_gateway_frame(
         %{
           "type" => "event",
           "event" => "chat",
           "payload" => %{"state" => "error"} = payload
         },
         state
       ) do
    error_msg = payload["error"] || payload["message"] || "Chat error"
    Logger.error("GatewaySocket: chat error state: #{error_msg}")
    notify_subscribers(state, {:gateway_event, {:error, error_msg}})
    {:ok, state}
  end

  # Catch-all for other events — surface error-like payloads instead of silently dropping
  defp handle_gateway_frame(%{"type" => "event"} = frame, state) do
    payload = frame["payload"] || %{}

    cond do
      is_map(payload) && (payload["error"] || payload["state"] == "error") ->
        error_msg = payload["error"] || payload["message"] || "Unknown agent error"
        Logger.error("GatewaySocket: error in unmatched event #{frame["event"]}: #{error_msg}")
        notify_subscribers(state, {:gateway_event, {:error, error_msg}})

      true ->
        Logger.debug("GatewaySocket: unmatched event: #{inspect(frame, limit: 500)}")
    end

    {:ok, state}
  end

  defp handle_gateway_frame(frame, state) do
    Logger.debug("GatewaySocket: unhandled frame: #{inspect(frame, limit: 200)}")
    {:ok, state}
  end

  # -- Private: helpers --

  defp extract_text(content) when is_list(content) do
    content
    |> Enum.filter(fn item -> item["type"] == "text" end)
    |> Enum.map_join("", fn item -> item["text"] || "" end)
    |> String.trim()
  end

  defp extract_text(_), do: ""

  defp extract_and_notify_text(content, state) do
    text = extract_text(content)

    if text != "" do
      # Send full text to replace any partial streaming content
      notify_subscribers(state, {:gateway_event, {:text_replace, text}})
      notify_subscribers(state, {:gateway_event, {:done, "chat-history"}})
    end
  end

  defp notify_subscribers(state, message) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, message)
    end)
  end

  defp generate_req_id do
    "req-#{System.unique_integer([:positive, :monotonic])}"
  end

  defp reset_idle_timer(state) do
    if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
    %{state | idle_timer: nil}
  end

  defp maybe_start_idle_timer(state) do
    if MapSet.size(state.subscribers) == 0 do
      if state.idle_timer, do: Process.cancel_timer(state.idle_timer)
      timer = Process.send_after(self(), :idle_timeout, @idle_timeout_ms)
      %{state | idle_timer: timer}
    else
      state
    end
  end
end
