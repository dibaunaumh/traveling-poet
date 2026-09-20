defmodule TravelingPoet.Apple do
  @moduledoc """
  Sign in with Apple, server side.

  The iOS app shows Apple's own sheet and gets back an identity token (a JWT
  saying who signed in) and a one-time authorization code. The token is
  verified here (`Apple.IdentityToken`). The code is traded with Apple for a
  refresh token, which is kept for one purpose only: Apple requires an app
  that offers account deletion to revoke its Sign in with Apple grant when
  the account is deleted (`revoke/1`), and revoking needs that token.

  Talking to Apple as "us" means a client secret: an ES256 JWT signed with
  the `.p8` key from the developer account, made fresh per request.

  Config (`config/runtime.exs`): `:apple_team_id`, `:apple_key_id`,
  `:apple_private_key` (the .p8's PEM text), `:apple_bundle_id`. Without all
  four `configured?/0` is false and the app offers no Apple button.
  """

  require Logger

  alias TravelingPoet.JWS

  @issuer "https://appleid.apple.com"
  @token_url "https://appleid.apple.com/auth/token"
  @revoke_url "https://appleid.apple.com/auth/revoke"
  @keys_url "https://appleid.apple.com/auth/keys"
  # Apple allows up to six months; a secret is made per request, so minutes do.
  @client_secret_ttl 300

  def issuer, do: @issuer
  def keys_url, do: @keys_url

  def configured? do
    Enum.all?([team_id(), key_id(), private_key(), bundle_id()], &(&1 not in [nil, ""]))
  end

  def bundle_id, do: Application.get_env(:traveling_poet, :apple_bundle_id)
  defp team_id, do: Application.get_env(:traveling_poet, :apple_team_id)
  defp key_id, do: Application.get_env(:traveling_poet, :apple_key_id)
  defp private_key, do: Application.get_env(:traveling_poet, :apple_private_key)

  @doc "The JWT that stands in for a client secret when calling Apple's token endpoints."
  def client_secret(now \\ System.os_time(:second)) do
    claims = %{
      "iss" => team_id(),
      "iat" => now,
      "exp" => now + @client_secret_ttl,
      "aud" => @issuer,
      "sub" => bundle_id()
    }

    JWS.sign_es256(%{"kid" => key_id()}, claims, {:pem, private_key()})
  end

  @doc "Trades the app's one-time authorization code for a refresh token."
  def exchange_code(code) when is_binary(code) and code != "" do
    form = %{
      "client_id" => bundle_id(),
      "client_secret" => client_secret(),
      "code" => code,
      "grant_type" => "authorization_code"
    }

    case post(@token_url, form) do
      {:ok, %{status: 200, body: %{"refresh_token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def exchange_code(_), do: {:error, :no_code}

  @doc "Withdraws the grant behind a refresh token. For account deletion."
  def revoke(refresh_token) when is_binary(refresh_token) and refresh_token != "" do
    form = %{
      "client_id" => bundle_id(),
      "client_secret" => client_secret(),
      "token" => refresh_token,
      "token_type_hint" => "refresh_token"
    }

    case post(@revoke_url, form) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke(_), do: {:error, :no_token}

  @doc false
  def req_options, do: Application.get_env(:traveling_poet, :apple_req_options, [])

  defp post(url, form) do
    [url: url, form: form, retry: false, receive_timeout: 10_000]
    |> Keyword.merge(req_options())
    |> Req.post()
  end
end
