defmodule TravelingPoet.GoogleAuth do
  @moduledoc """
  The companion's Google grant, shared by every Google feature.

  Google issues one grant per user per OAuth client: asking for Calendar on
  top of Drive replaces the refresh token, and revoking it revokes every
  scope. So the tokens live once on the user (`google_*`) with the feature
  scopes they carry, and each feature (`:drive`, `:calendar`) is a scope plus
  a `<feature>_connected_at` stamp.

  Consent is incremental through the same Google sign-in: `consent_params/2`
  asks for the feature's scope together with every scope the account already
  holds, so connecting one feature never drops another. Disconnecting a
  feature forgets its scope; the grant is revoked with Google only when the
  last feature goes.

  Every request goes through `req_options/0`, stubbed with `Req.Test` in the
  suite (`:google_req_options`); nothing here reaches Google from a test.
  """

  require Logger

  alias TravelingPoet.Accounts
  alias TravelingPoet.Accounts.User

  @features %{
    drive: "https://www.googleapis.com/auth/drive.file",
    calendar: "https://www.googleapis.com/auth/calendar.events.readonly"
  }
  @token_url "https://oauth2.googleapis.com/token"
  @revoke_url "https://oauth2.googleapis.com/revoke"

  def features, do: Map.keys(@features)

  def scope(feature), do: Map.fetch!(@features, feature)

  def configured? do
    Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, [])[:client_id] not in [
      nil,
      ""
    ]
  end

  @doc """
  The Google sign-in query that asks for `feature` on top of sign-in, keeping
  every scope the account already holds. Offline access, and a fresh consent
  screen so Google hands back a refresh token.
  """
  def consent_params(%User{} = user, feature) do
    scopes = Enum.uniq(["email", "profile"] ++ held_scopes(user) ++ [scope(feature)])

    [
      scope: Enum.join(scopes, " "),
      access_type: "offline",
      prompt: "consent",
      login_hint: user.email
    ]
  end

  def connected?(%User{google_refresh_token: t} = user, feature) when is_binary(t) and t != "",
    do: scope(feature) in held_scopes(user)

  def connected?(_user, _feature), do: false

  @doc """
  Keeps the grant from an OAuth callback for `feature`. `{:error,
  :scope_not_granted}` when the companion unticked it on the consent screen,
  `{:error, :no_refresh_token}` when Google gave no offline access.

  The new token replaces the old one, so the scopes kept are exactly those
  this token carries among the feature asked for and the features already
  connected: a feature unticked on the screen is dropped, and a feature the
  companion disconnected earlier does not come back unasked.
  """
  def store_credentials(%User{} = user, %{scopes: scopes} = credentials, feature) do
    granted = List.wrap(scopes)

    cond do
      scope(feature) not in granted ->
        {:error, :scope_not_granted}

      credentials.refresh_token in [nil, ""] ->
        {:error, :no_refresh_token}

      true ->
        kept = Enum.filter(Enum.uniq(held_scopes(user) ++ [scope(feature)]), &(&1 in granted))

        attrs =
          %{
            google_refresh_token: credentials.refresh_token,
            google_access_token: credentials.token,
            google_token_expires_at: expires_at(credentials.expires_at),
            google_scopes: kept
          }
          |> Map.merge(connected_at_attrs(kept, now()))

        Accounts.update_user(user, attrs)
    end
  end

  @doc """
  Forgets `feature`. The grant itself is revoked with Google (best effort)
  only when no other feature still uses it.
  """
  def disconnect(%User{} = user, feature) do
    remaining = List.delete(held_scopes(user), scope(feature))

    cond do
      not connected?(user, feature) and remaining == [] ->
        forget_all(user)

      remaining == [] ->
        revoke(user)
        forget_all(user)

      true ->
        Accounts.update_user(
          user,
          Map.put(%{google_scopes: remaining}, connected_at_field(feature), nil)
        )
    end
  end

  @doc false
  # A usable access token, refreshed when it is within a minute of expiring.
  # Returns the updated user so callers thread it forward.
  def access_token(%User{} = user) do
    fresh? =
      user.google_access_token not in [nil, ""] and user.google_token_expires_at &&
        DateTime.compare(user.google_token_expires_at, DateTime.add(DateTime.utc_now(), 60)) ==
          :gt

    if fresh?, do: {:ok, user, user.google_access_token}, else: refresh(user)
  end

  defp refresh(%User{google_refresh_token: refresh}) when refresh in [nil, ""],
    do: {:error, :reconnect}

  defp refresh(%User{} = user) do
    oauth = Application.get_env(:ueberauth, Ueberauth.Strategy.Google.OAuth, [])

    form = [
      grant_type: "refresh_token",
      refresh_token: user.google_refresh_token,
      client_id: oauth[:client_id],
      client_secret: oauth[:client_secret]
    ]

    case Req.post(@token_url, [form: form] ++ req_options()) do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}} ->
        {:ok, user} =
          Accounts.update_user(user, %{
            google_access_token: token,
            google_token_expires_at: DateTime.add(now(), body["expires_in"] || 3600)
          })

        {:ok, user, token}

      {:ok, %{status: status, body: %{"error" => "invalid_grant"}}} when status in 400..401 ->
        # revoked in their Google account, or expired: every feature is gone
        forget_all(user)
        {:error, :reconnect}

      other ->
        {:error, {:token, summarize(other)}}
    end
  end

  defp revoke(%User{google_refresh_token: token}) when is_binary(token) and token != "" do
    case Req.post(@revoke_url, [form: [token: token]] ++ req_options()) do
      {:ok, %{status: s}} when s in 200..299 -> :ok
      other -> Logger.info("GoogleAuth: revoke answered #{inspect(other)}; forgetting anyway")
    end
  end

  defp revoke(_user), do: :ok

  defp forget_all(user) do
    attrs =
      %{
        google_refresh_token: nil,
        google_access_token: nil,
        google_token_expires_at: nil,
        google_scopes: []
      }
      |> Map.merge(connected_at_attrs([], nil))

    Accounts.update_user(user, attrs)
  end

  defp held_scopes(%User{google_scopes: scopes}), do: List.wrap(scopes)

  # `<feature>_connected_at` for every feature: stamped when the kept scopes
  # carry it, cleared otherwise. (A stamp for a feature the schema does not
  # have yet is dropped by the changeset.)
  defp connected_at_attrs(kept, stamp) do
    Map.new(@features, fn {feature, scope} ->
      {connected_at_field(feature), if(scope in kept, do: stamp, else: nil)}
    end)
  end

  defp connected_at_field(:drive), do: :drive_connected_at
  defp connected_at_field(:calendar), do: :calendar_connected_at

  defp summarize({:ok, %{status: status, body: body}}),
    do: "HTTP #{status}: #{inspect(body) |> String.slice(0, 200)}"

  defp summarize({:error, reason}), do: inspect(reason) |> String.slice(0, 200)
  defp summarize(other), do: inspect(other) |> String.slice(0, 200)

  defp expires_at(unix) when is_integer(unix),
    do: DateTime.from_unix!(unix) |> DateTime.truncate(:second)

  defp expires_at(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  def req_options, do: Application.get_env(:traveling_poet, :google_req_options, [])
end
