defmodule TravelingPoet.Apns do
  @moduledoc """
  Push notifications to the iOS app, through Apple's push service.

  The app is a web view, and a web view has no Web Push, so what
  `TravelingPoet.WebPush` does for browsers this does for the app: same
  moments, same words (`WebPush`'s payload builders feed both; see
  `WebPush.notify_user/2`), another road. A device that turns notifications
  on hands over its APNs token; a notification is one HTTP/2 POST per device
  to Apple, authorized by a short-lived ES256 token signed with the `.p8` key
  that also signs Sign in with Apple (`TravelingPoet.Apple`'s config; without
  it `configured?/0` is false and nothing here runs).

  Apple throttles senders that mint a new provider token too often, so one
  is kept for 50 minutes (they are valid for 60). A token Apple no longer
  knows (410, or 400 BadDeviceToken) is deleted, as a dead browser
  subscription is. Tokens are per build flavour: a debug build's only works
  against the sandbox host, so each row remembers which it is.
  """

  import Ecto.Query

  require Logger

  alias TravelingPoet.Apns.Device
  alias TravelingPoet.{Apple, JWS, Repo}

  @hosts %{
    "production" => "https://api.push.apple.com",
    "sandbox" => "https://api.sandbox.push.apple.com"
  }
  @jwt_cache {__MODULE__, :provider_token}
  @jwt_ttl 50 * 60
  @expiry_seconds 24 * 3600

  def configured?, do: Apple.configured?()

  @doc "Remembers (or re-homes) a device. One phone, one row, whoever is signed in on it."
  def register(%{id: user_id}, token, environment) when is_binary(token) do
    attrs = %{
      user_id: user_id,
      token: String.downcase(token),
      environment: environment || "production"
    }

    %Device{}
    |> Device.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:user_id, :environment, :last_error, :updated_at]},
      conflict_target: :token
    )
  end

  def register(_user, _token, _environment), do: {:error, :invalid}

  @doc "Forgets a device, if it is this user's."
  def unregister(%{id: user_id}, token) when is_binary(token) do
    {count, _} =
      Repo.delete_all(
        from d in Device, where: d.user_id == ^user_id and d.token == ^String.downcase(token)
      )

    count
  end

  def unregister(_user, _token), do: 0

  def list_devices(user_id) when is_integer(user_id) do
    if configured?(), do: Repo.all(from d in Device, where: d.user_id == ^user_id), else: []
  end

  def count(%{id: user_id}),
    do: Repo.aggregate(from(d in Device, where: d.user_id == ^user_id), :count)

  def registered?(%{id: user_id}, token) when is_binary(token),
    do:
      Repo.exists?(
        from d in Device, where: d.user_id == ^user_id and d.token == ^String.downcase(token)
      )

  def registered?(_, _), do: false

  @doc """
  Sends one payload (the shape `WebPush`'s builders make: `title`, `body`,
  `url`, `tag`) to each device. Returns `{sent, pruned}`.
  """
  def deliver(devices, payload) when is_list(devices) do
    Enum.reduce(devices, {0, 0}, fn device, {sent, pruned} ->
      case push(device, payload) do
        :ok -> {sent + 1, pruned}
        {:error, :gone} -> {sent, pruned + 1}
        {:error, _} -> {sent, pruned}
      end
    end)
  end

  @doc "The JSON Apple is sent: what to show, and where a tap should lead."
  def notification(payload) do
    %{
      "aps" => %{
        "alert" => %{"title" => payload[:title], "body" => payload[:body]},
        "sound" => "default",
        # one conversation per kind of note in Notification Centre
        "thread-id" => payload[:tag] |> to_string() |> String.split("-") |> hd()
      },
      # read by the page when the notification is tapped (native.js)
      "url" => payload[:url]
    }
  end

  defp push(%Device{} = device, payload) do
    request =
      [
        url: "#{@hosts[device.environment]}/3/device/#{device.token}",
        json: notification(payload),
        headers: headers(payload),
        # Not [:http2] alone: Finch opens an HTTP/2-only pool in the
        # background and refuses requests until it is up
        # (:pool_not_available). Notifications are rare, so every one met a
        # cold pool and none ever reached Apple. Offering both lets the
        # request open its own connection; ALPN still settles on HTTP/2,
        # which is all Apple speaks.
        connect_options: [protocols: [:http1, :http2]],
        retry: false,
        receive_timeout: 15_000
      ]
      |> Keyword.merge(req_options())

    case Req.post(request) do
      {:ok, %{status: 200}} ->
        mark(device, %{last_sent_at: DateTime.utc_now(:second), last_error: nil})
        :ok

      {:ok, %{status: status, body: body}} ->
        reason = reason(body)

        if status == 410 or reason in ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"] do
          Repo.delete(device)
          {:error, :gone}
        else
          # An expired provider token is ours to fix, not the device's.
          if reason in ["ExpiredProviderToken", "InvalidProviderToken"],
            do: forget_provider_token()

          Logger.warning("apns: device #{device.id} refused #{status} #{reason}")
          mark(device, %{last_error: String.slice("#{status} #{reason}", 0, 255)})
          {:error, {:http, status, reason}}
        end

      {:error, error} ->
        Logger.warning("apns: device #{device.id}: #{inspect(error)}")
        mark(device, %{last_error: String.slice(inspect(error), 0, 255)})
        {:error, error}
    end
  end

  defp headers(payload) do
    [
      {"authorization", "bearer " <> provider_token()},
      {"apns-topic", Apple.bundle_id()},
      {"apns-push-type", "alert"},
      {"apns-priority", "10"},
      {"apns-expiration", Integer.to_string(System.os_time(:second) + @expiry_seconds)}
    ] ++ collapse_id(payload[:tag])
  end

  # A revised entry replaces its own earlier note instead of stacking under it.
  defp collapse_id(tag) when is_binary(tag) and byte_size(tag) in 1..64,
    do: [{"apns-collapse-id", tag}]

  defp collapse_id(_), do: []

  defp reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp reason(_), do: "unknown"

  @doc false
  def provider_token(now \\ System.os_time(:second)) do
    case :persistent_term.get(@jwt_cache, nil) do
      {token, minted_at} when now - minted_at < @jwt_ttl ->
        token

      _ ->
        token =
          JWS.sign_es256(
            %{"kid" => Application.get_env(:traveling_poet, :apple_key_id)},
            %{"iss" => Application.get_env(:traveling_poet, :apple_team_id), "iat" => now},
            {:pem, Application.get_env(:traveling_poet, :apple_private_key)}
          )

        :persistent_term.put(@jwt_cache, {token, now})
        token
    end
  end

  @doc false
  def forget_provider_token, do: :persistent_term.erase(@jwt_cache)

  defp mark(device, attrs), do: device |> Device.changeset(attrs) |> Repo.update()

  @doc false
  def req_options, do: Application.get_env(:traveling_poet, :apns_req_options, [])
end
