defmodule TravelingPoetWeb.SessionToken do
  @moduledoc ~S"""
  Short-lived signed tokens that prove a given `user_id` owns an active session,
  issued by `/api/generate_token` and consumed by endpoints that need to
  authenticate a user outside the browser cookie context (the Unity WebGL client
  and the artifact-serving endpoint).

  Format: `Base64URL("#{user_id}:#{timestamp}:#{hmac_sha256(secret, "#{user_id}:#{timestamp}")}")`.
  Signed with the endpoint's `secret_key_base`. Lifetime is 5 minutes.
  """

  @max_age_seconds 300

  def max_age_seconds, do: @max_age_seconds

  def create(user_id) when is_integer(user_id) do
    timestamp = System.system_time(:second)
    data = "#{user_id}:#{timestamp}"
    signature = sign_data(data)
    Base.url_encode64("#{data}:#{signature}", padding: false)
  end

  def verify(token) when is_binary(token) do
    with {:ok, decoded} <- Base.url_decode64(token, padding: false),
         [user_id_str, timestamp_str, signature] <- String.split(decoded, ":"),
         {user_id, ""} <- Integer.parse(user_id_str),
         {timestamp, ""} <- Integer.parse(timestamp_str),
         true <- verify_signature("#{user_id}:#{timestamp}", signature),
         true <- not_expired?(timestamp) do
      {:ok, user_id}
    else
      false -> {:error, :expired}
      _ -> {:error, :invalid}
    end
  end

  def verify(_), do: {:error, :invalid}

  defp sign_data(data) do
    :crypto.mac(:hmac, :sha256, secret_key(), data) |> Base.encode64(padding: false)
  end

  defp verify_signature(data, signature) do
    expected = sign_data(data)
    Plug.Crypto.secure_compare(signature, expected)
  end

  defp not_expired?(timestamp) do
    System.system_time(:second) - timestamp <= @max_age_seconds
  end

  defp secret_key do
    Application.get_env(:traveling_poet, TravelingPoetWeb.Endpoint)[:secret_key_base]
  end
end
