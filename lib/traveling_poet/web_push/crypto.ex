defmodule TravelingPoet.WebPush.Crypto do
  @moduledoc """
  The two cryptographic halves of Web Push, on `:crypto` alone:

    * message encryption per RFC 8291 (`aes128gcm` content coding, RFC 8188),
      so only the subscribing browser can read the payload; and
    * VAPID (RFC 8292): an ES256-signed JWT that tells the push service which
      application server is talking, keyed by the VAPID key pair in config.

  Keys travel as base64url without padding, the format every browser and
  `web-push` CLI emits, so a pair generated anywhere works here.
  """

  @curve :prime256v1
  # Largest single record we will ever need; entries are a few hundred bytes.
  @record_size 4096
  # Push services accept up to 24h; 12h keeps clock skew comfortably inside.
  @jwt_ttl_seconds 12 * 3600

  @doc "A fresh VAPID key pair, both halves base64url (no padding)."
  def generate_vapid_keys do
    {public, private} = :crypto.generate_key(:ecdh, @curve)
    %{public_key: b64(public), private_key: b64(private)}
  end

  @doc """
  Encrypts `plaintext` for the subscription identified by its `p256dh`
  (browser public key) and `auth` (16-byte secret), both base64url.

  Returns the complete `aes128gcm` body: header (salt, record size, our
  ephemeral public key) followed by the single encrypted record.
  """
  def encrypt(plaintext, p256dh, auth) when is_binary(plaintext) do
    ua_public = unb64(p256dh)
    auth_secret = unb64(auth)

    if byte_size(ua_public) != 65 or byte_size(auth_secret) != 16 do
      {:error, :bad_subscription_keys}
    else
      {as_public, as_private} = :crypto.generate_key(:ecdh, @curve)
      salt = :crypto.strong_rand_bytes(16)

      shared = :crypto.compute_key(:ecdh, ua_public, as_private, @curve)

      # RFC 8291 §3.3–3.4: combine the ECDH secret with the auth secret and
      # both public keys before the RFC 8188 key schedule.
      ikm =
        hkdf(auth_secret, shared, "WebPush: info" <> <<0>> <> ua_public <> as_public, 32)

      cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm" <> <<0>>, 16)
      nonce = hkdf(salt, ikm, "Content-Encoding: nonce" <> <<0>>, 12)

      # 0x02 marks the last (only) record; no extra padding needed.
      padded = plaintext <> <<2>>

      {ciphertext, tag} =
        :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, padded, <<>>, 16, true)

      header = salt <> <<@record_size::unsigned-big-32>> <> <<65>> <> as_public
      {:ok, header <> ciphertext <> tag}
    end
  rescue
    ArgumentError -> {:error, :bad_subscription_keys}
  end

  @doc """
  The `Authorization` header value for a push to `endpoint`: a VAPID JWT
  scoped to the push service's origin, plus our public key.
  """
  def vapid_authorization(
        endpoint,
        subject,
        public_key,
        private_key,
        now \\ System.os_time(:second)
      ) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)
    audience = URI.to_string(%URI{scheme: scheme, host: host, port: port})

    claims = %{"aud" => audience, "exp" => now + @jwt_ttl_seconds, "sub" => subject}
    jwt = TravelingPoet.JWS.sign_es256(%{"typ" => "JWT"}, claims, {:raw, unb64(private_key)})

    "vapid t=#{jwt},k=#{public_key}"
  end

  # -- helpers --

  # HKDF (RFC 5869) with SHA-256, for outputs no longer than one hash block.
  defp hkdf(salt, ikm, info, length) when length <= 32 do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>) |> binary_part(0, length)
  end

  def b64(bin), do: Base.url_encode64(bin, padding: false)

  def unb64(str) do
    str |> String.trim_trailing("=") |> Base.url_decode64!(padding: false)
  end
end
