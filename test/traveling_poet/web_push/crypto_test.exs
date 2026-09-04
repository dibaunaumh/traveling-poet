defmodule TravelingPoet.WebPush.CryptoTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.WebPush.Crypto

  @curve :prime256v1

  # The browser's side of RFC 8291, written from the RFC so the test fails if
  # the sender drifts from it rather than from itself.
  defp browser_decrypt(body, ua_private, ua_public, auth_secret) do
    <<salt::binary-16, _rs::unsigned-big-32, 65, as_public::binary-65, rest::binary>> = body
    ct_len = byte_size(rest) - 16
    <<ciphertext::binary-size(ct_len), tag::binary-16>> = rest

    shared = :crypto.compute_key(:ecdh, as_public, ua_private, @curve)
    ikm = hkdf(auth_secret, shared, "WebPush: info" <> <<0>> <> ua_public <> as_public, 32)
    cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce" <> <<0>>, 12)

    padded = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false)
    padded |> String.trim_trailing(<<0>>) |> String.trim_trailing(<<2>>)
  end

  defp hkdf(salt, ikm, info, len) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>) |> binary_part(0, len)
  end

  test "a browser holding the subscription keys can read the payload" do
    {ua_public, ua_private} = :crypto.generate_key(:ecdh, @curve)
    auth = :crypto.strong_rand_bytes(16)
    plaintext = Jason.encode!(%{title: "Nam wrote from Ronda", url: "/journal/2026-09-04"})

    {:ok, body} = Crypto.encrypt(plaintext, Crypto.b64(ua_public), Crypto.b64(auth))

    # aes128gcm header: 16 salt + 4 rs + 1 idlen + 65 key, then ct + 16 tag + 1 delimiter
    assert byte_size(body) == 86 + byte_size(plaintext) + 1 + 16
    assert browser_decrypt(body, ua_private, ua_public, auth) == plaintext
  end

  test "each message gets its own salt and ephemeral key" do
    {ua_public, _} = :crypto.generate_key(:ecdh, @curve)
    auth = Crypto.b64(:crypto.strong_rand_bytes(16))
    {:ok, a} = Crypto.encrypt("x", Crypto.b64(ua_public), auth)
    {:ok, b} = Crypto.encrypt("x", Crypto.b64(ua_public), auth)
    assert binary_part(a, 0, 86) != binary_part(b, 0, 86)
  end

  test "rejects keys no push service could have issued" do
    assert {:error, :bad_subscription_keys} =
             Crypto.encrypt("x", Crypto.b64("short"), Crypto.b64("a"))

    assert {:error, :bad_subscription_keys} = Crypto.encrypt("x", "!!!not base64!!!", "AAAA")
  end

  test "VAPID header carries a JWT the push service can verify with our public key" do
    %{public_key: pub, private_key: priv} = Crypto.generate_vapid_keys()
    now = 1_800_000_000

    header =
      Crypto.vapid_authorization(
        "https://fcm.googleapis.com/fcm/send/abc:def",
        "mailto:poet@example.com",
        pub,
        priv,
        now
      )

    assert "vapid t=" <> rest = header
    [jwt, "k=" <> ^pub] = String.split(rest, ",")
    [h, c, sig] = String.split(jwt, ".")

    assert Jason.decode!(Crypto.unb64(h)) == %{"typ" => "JWT", "alg" => "ES256"}

    assert Jason.decode!(Crypto.unb64(c)) == %{
             "aud" => "https://fcm.googleapis.com",
             "sub" => "mailto:poet@example.com",
             "exp" => now + 12 * 3600
           }

    raw = Crypto.unb64(sig)
    assert byte_size(raw) == 64

    assert :crypto.verify(
             :ecdsa,
             :sha256,
             h <> "." <> c,
             raw_to_der(raw),
             [Crypto.unb64(pub), @curve]
           )
  end

  defp raw_to_der(<<r::binary-32, s::binary-32>>) do
    r = der_int(r)
    s = der_int(s)
    <<0x30, byte_size(r) + byte_size(s)>> <> r <> s
  end

  defp der_int(bin) do
    bin = bin |> :binary.decode_unsigned() |> :binary.encode_unsigned()
    bin = if :binary.first(bin) >= 0x80, do: <<0>> <> bin, else: bin
    <<0x02, byte_size(bin)>> <> bin
  end
end
