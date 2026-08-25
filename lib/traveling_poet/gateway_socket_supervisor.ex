defmodule TravelingPoet.GatewaySocketSupervisor do
  @moduledoc """
  Manages GatewaySocket processes via DynamicSupervisor.
  Provides helpers to ensure connections exist and to disconnect.
  """

  require Logger

  def ensure_connected(user) do
    case TravelingPoet.GatewaySocket.whereis(user.id) do
      nil ->
        start_socket(user)

      pid ->
        {:ok, pid}
    end
  end

  def disconnect(user_id) do
    case TravelingPoet.GatewaySocket.whereis(user_id) do
      nil ->
        :ok

      pid ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
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
