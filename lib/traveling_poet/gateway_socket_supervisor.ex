defmodule TravelingPoet.GatewaySocketSupervisor do
  @moduledoc """
  Manages GatewaySocket processes via DynamicSupervisor.
  Provides helpers to ensure connections exist and to disconnect.
  """

  require Logger

  alias TravelingPoet.SpritesClient

  @retry_delay_ms 4_000

  @doc """
  Ensures a live GatewaySocket for the user.

  The first WebSocket connect can fail transiently: a suspended sprite 502s
  or times out while it cold-starts, and right after (re)provisioning the
  gateway service needs a few seconds to bind its port. Pass `attempts: n`
  to retry through that window — after the first failure the sprite is woken
  with a blocking exec, then connects are retried #{@retry_delay_ms}ms apart.
  Headless callers (scheduler, Telegram, smoke test) should use several
  attempts; LiveView keeps the default single fast attempt and recovers via
  its own wake-and-retry on chat send.

  `within_ms: n` keeps retrying until n ms have passed, however many
  attempts that takes. A sprite that wakes from a cold boot starts its
  gateway from scratch, which took 50 to 85 seconds on 2026-11-12, and
  six attempts (about half a minute) gave up on three poets' daily runs
  before their gateways were ready. A user with no device keys can never
  connect and is not retried. `retry_delay_ms` is for tests.
  """
  def ensure_connected(user, opts \\ []) do
    attempts = Keyword.get(opts, :attempts, 1)
    delay = Keyword.get(opts, :retry_delay_ms, @retry_delay_ms)

    deadline =
      case Keyword.get(opts, :within_ms) do
        nil -> nil
        ms -> System.monotonic_time(:millisecond) + ms
      end

    connect(user, 1, attempts, deadline, delay)
  end

  defp connect(user, i, attempts, deadline, delay) do
    case try_connect(user) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :no_device_keys} = err ->
        err

      {:error, _} = err ->
        if i < attempts or before?(deadline, delay) do
          # Synchronous wake: exec returns once the sprite is running.
          if i == 1 and is_binary(user.sprite_name) do
            client().exec(user.sprite_name, "true")
          end

          Process.sleep(delay)
          connect(user, i + 1, attempts, deadline, delay)
        else
          err
        end
    end
  end

  defp before?(nil, _delay), do: false
  defp before?(deadline, delay), do: System.monotonic_time(:millisecond) + delay < deadline

  defp client, do: Application.get_env(:traveling_poet, :sprites_client, SpritesClient)

  def disconnect(user_id) do
    case TravelingPoet.GatewaySocket.whereis(user_id) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end

  defp try_connect(user) do
    case TravelingPoet.GatewaySocket.whereis(user.id) do
      nil ->
        # Refetch: callers often hold a stale struct (a LiveView assign from
        # mount) whose sprite_url/tokens/device keys may have been rotated by
        # a re-provision since. Connect with what the DB says now.
        start_socket(TravelingPoet.Accounts.get_user(user.id) || user)

      pid ->
        {:ok, pid}
    end
  end

  defp start_socket(user) do
    if !(user.device_public_key && user.device_private_key) do
      Logger.warning("GatewaySocket: user #{user.id} has no device keys, cannot connect")
      {:error, :no_device_keys}
    else
      opts = [
        user_id: user.id,
        sprite_url: user.sprite_url,
        gateway_token: user.gateway_token,
        sprite_name: user.sprite_name,
        device_keys: {user.device_public_key, user.device_private_key}
      ]

      case DynamicSupervisor.start_child(__MODULE__, {TravelingPoet.GatewaySocket, opts}) do
        {:ok, pid} ->
          Logger.info("GatewaySocket started for user #{user.id}")
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          {:ok, pid}

        {:error, reason} = error ->
          Logger.error("Failed to start GatewaySocket for user #{user.id}: #{inspect(reason)}")
          error
      end
    end
  end
end
