defmodule TravelingPoet.Apple.IdentityToken do
  @moduledoc """
  Verifies the identity token the iOS app gets from Apple's sign-in sheet.

  It is an RS256 JWT signed by one of the keys Apple publishes at
  `/auth/keys`. Trusting it takes the signature AND the claims: issued by
  Apple, for THIS app (`aud` is the bundle id; a token minted for any other
  app is a valid Apple token and must be refused), not expired, and carrying
  the nonce this session asked for, so a token captured elsewhere cannot be
  replayed here.

  Apple's keys rotate rarely. They are cached for a day, and fetched again
  at once when a token names a key the cache has never heard of.
  """

  alias TravelingPoet.{Apple, JWS}

  @cache_key {__MODULE__, :jwks}
  @cache_ttl 24 * 3600

  @type identity :: %{
          sub: String.t(),
          email: String.t() | nil,
          email_verified: boolean,
          private_relay: boolean
        }

  @doc """
  `raw_nonce` is what this session generated; the app was given its SHA-256
  (hex) to pass to Apple, and Apple copies that into the token.
  """
  @spec verify(String.t(), String.t()) :: {:ok, identity} | {:error, atom}
  def verify(token, raw_nonce) when is_binary(token) and is_binary(raw_nonce) do
    with {:ok, claims} <- verify_signature(token),
         :ok <- check(claims["iss"] == Apple.issuer(), :wrong_issuer),
         :ok <- check(audience?(claims["aud"]), :wrong_audience),
         :ok <- check(is_integer(claims["exp"]) and claims["exp"] > now(), :expired),
         :ok <- check(nonce?(claims["nonce"], raw_nonce), :wrong_nonce),
         :ok <- check(is_binary(claims["sub"]) and claims["sub"] != "", :no_subject) do
      email = claims["email"]

      {:ok,
       %{
         sub: claims["sub"],
         email: if(is_binary(email) and email != "", do: String.downcase(email)),
         email_verified: truthy?(claims["email_verified"]),
         private_relay: truthy?(claims["is_private_email"]) or relay_address?(email)
       }}
    end
  end

  def verify(_, _), do: {:error, :malformed}

  @doc "The value the app hands Apple for a session's raw nonce."
  def hashed_nonce(raw_nonce),
    do: :sha256 |> :crypto.hash(raw_nonce) |> Base.encode16(case: :lower)

  defp verify_signature(token) do
    case JWS.verify_rs256(token, jwks()) do
      {:error, :unknown_key} -> JWS.verify_rs256(token, jwks(:refresh))
      result -> result
    end
  end

  defp audience?(aud), do: is_binary(aud) and aud == Apple.bundle_id()

  defp nonce?(claimed, raw) when is_binary(claimed),
    do: Plug.Crypto.secure_compare(claimed, hashed_nonce(raw))

  defp nonce?(_, _), do: false

  # Apple sends these as booleans in some tokens and as "true"/"false" in others.
  defp truthy?(value), do: value in [true, "true"]

  defp relay_address?(email) when is_binary(email),
    do: String.ends_with?(String.downcase(email), "@privaterelay.appleid.com")

  defp relay_address?(_), do: false

  defp check(true, _reason), do: :ok
  defp check(_, reason), do: {:error, reason}

  defp now, do: System.os_time(:second)

  defp jwks(mode \\ :cached) do
    case {mode, :persistent_term.get(@cache_key, nil)} do
      {:cached, {keys, fetched_at}} when is_list(keys) ->
        if now() - fetched_at < @cache_ttl, do: keys, else: fetch()

      _ ->
        fetch()
    end
  end

  defp fetch do
    request =
      Keyword.merge(
        [url: Apple.keys_url(), retry: false, receive_timeout: 10_000],
        Apple.req_options()
      )

    case Req.get(request) do
      {:ok, %{status: 200, body: %{"keys" => keys}}} when is_list(keys) ->
        :persistent_term.put(@cache_key, {keys, now()})
        keys

      _ ->
        # Better a day-old key set than no sign-in while Apple hiccups.
        case :persistent_term.get(@cache_key, nil) do
          {keys, _} -> keys
          nil -> []
        end
    end
  end

  @doc false
  def forget_keys, do: :persistent_term.erase(@cache_key)
end
