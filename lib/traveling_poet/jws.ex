defmodule TravelingPoet.JWS do
  @moduledoc """
  Signed JSON tokens (JWS/JWT), on `:crypto` and `:public_key` alone.

  Three conversations need them and none is worth a dependency: Web Push
  signs VAPID tokens with a raw P-256 scalar, and everything Apple (Sign in
  with Apple's client secret, later APNs and the App Store) signs with the
  PKCS#8 `.p8` key Apple issues, both ES256. Apple's identity tokens arrive
  signed RS256 against keys Apple publishes as a JWK set.

  The App Store signs what it sends (transactions, server notifications) ES256
  too, with the signing certificate's whole chain inside the token.

  This module only does the cryptography and the encoding. What a token must
  CLAIM (issuer, audience, expiry, nonce) is the caller's business.
  """

  @curve :prime256v1

  @typedoc "An ES256 signing key: the raw 32-byte scalar, or a PEM (`.p8`) document."
  @type es256_key :: {:raw, binary} | {:pem, String.t()}

  @doc "A compact ES256 JWS over `claims`, with `header` merged over `alg`."
  @spec sign_es256(map, map, es256_key) :: String.t()
  def sign_es256(header, claims, key) do
    header = Map.put(header, "alg", "ES256")
    signing_input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    signing_input <> "." <> b64(signing_input |> ecdsa(key) |> der_to_raw())
  end

  defp ecdsa(input, {:raw, scalar}), do: :crypto.sign(:ecdsa, :sha256, input, [scalar, @curve])

  defp ecdsa(input, {:pem, pem}) do
    [entry | _] = :public_key.pem_decode(pem)
    :public_key.sign(input, :sha256, :public_key.pem_entry_decode(entry))
  end

  @doc """
  The header and claims of a compact JWS, WITHOUT checking its signature.
  For picking the key to verify with; never for trusting what it says.
  """
  @spec peek(String.t()) :: {:ok, map, map} | {:error, :malformed}
  def peek(token) when is_binary(token) do
    with [h, c, _sig] <- String.split(token, "."),
         {:ok, header} <- decode_part(h),
         {:ok, claims} <- decode_part(c) do
      {:ok, header, claims}
    else
      _ -> {:error, :malformed}
    end
  end

  def peek(_), do: {:error, :malformed}

  @doc """
  Verifies an RS256 JWS against a JWK set (a list of JWK maps) and returns
  its claims. The key is chosen by the token's `kid`; a token naming any
  other algorithm is refused outright, whatever its signature says.
  """
  @spec verify_rs256(String.t(), [map]) ::
          {:ok, map} | {:error, :malformed | :unsupported_alg | :unknown_key | :bad_signature}
  def verify_rs256(token, jwks) when is_binary(token) and is_list(jwks) do
    with {:ok, header, claims} <- peek(token),
         :ok <- expect_alg(header, "RS256"),
         {:ok, key} <- rsa_key(jwks, header["kid"]),
         [h, c, sig] = String.split(token, "."),
         {:ok, signature} <- Base.url_decode64(sig, padding: false),
         true <- :public_key.verify(h <> "." <> c, :sha256, signature, key) do
      {:ok, claims}
    else
      false -> {:error, :bad_signature}
      :error -> {:error, :malformed}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_rs256(_, _), do: {:error, :malformed}

  @doc """
  Verifies an ES256 JWS that carries its own certificate chain (`x5c`), the
  form the App Store signs transactions and server notifications in.

  The chain in the token proves nothing by itself: anyone can mint one. It is
  trusted only if it leads to `root_der`, a root certificate the CALLER
  already holds, and the token's own copy of the root is ignored. The
  signature is then checked with the leaf certificate's key.

  `opts[:require_oids]` is a list of `{position, oid}` (position `:leaf` or
  `:intermediate`, `oid` a tuple) that must be present as certificate
  extensions: Apple marks the certificates allowed to sign for the App Store
  this way, so a different Apple-issued certificate is not enough.

  Returns the claims, plus the chain's DER certificates for a caller that
  wants to look closer.
  """
  @spec verify_es256_x5c(String.t(), binary, keyword) ::
          {:ok, map}
          | {:error,
             :malformed | :unsupported_alg | :bad_chain | :untrusted_chain | :bad_signature}
  def verify_es256_x5c(token, root_der, opts \\ []) when is_binary(root_der) do
    with {:ok, header, claims} <- peek(token),
         :ok <- expect_alg(header, "ES256"),
         {:ok, [leaf, intermediate | _]} <- chain(header["x5c"]),
         :ok <- trusted?(root_der, intermediate, leaf),
         :ok <- marked?(opts[:require_oids] || [], leaf, intermediate),
         [h, c, sig] = String.split(token, "."),
         {:ok, <<_::binary-size(64)>> = raw} <- Base.url_decode64(sig, padding: false),
         true <- :public_key.verify(h <> "." <> c, :sha256, raw_to_der(raw), leaf_key(leaf)) do
      {:ok, claims}
    else
      false -> {:error, :bad_signature}
      :error -> {:error, :malformed}
      {:ok, _not_64_bytes} -> {:error, :malformed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chain(x5c) when is_list(x5c) and length(x5c) >= 2 do
    ders = Enum.map(x5c, &Base.decode64/1)

    if Enum.all?(ders, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(ders, fn {:ok, der} -> der end)},
      else: {:error, :bad_chain}
  end

  defp chain(_), do: {:error, :bad_chain}

  # Path validation from OUR root down: issuer/subject links, signatures and
  # validity dates of the intermediate and the leaf.
  defp trusted?(root_der, intermediate, leaf) do
    case :public_key.pkix_path_validation(root_der, [intermediate, leaf], []) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :untrusted_chain}
    end
  rescue
    _ -> {:error, :bad_chain}
  end

  defp marked?(required, leaf, intermediate) do
    certs = %{leaf: leaf, intermediate: intermediate}

    if Enum.all?(required, fn {position, oid} -> oid in extension_oids(certs[position]) end),
      do: :ok,
      else: {:error, :untrusted_chain}
  end

  defp extension_oids(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    # #'OTPTBSCertificate'{}: the extensions are its last field
    case elem(tbs, tuple_size(tbs) - 1) do
      extensions when is_list(extensions) -> Enum.map(extensions, &elem(&1, 1))
      _ -> []
    end
  end

  defp leaf_key(der) do
    {:OTPCertificate, tbs, _, _} = :public_key.pkix_decode_cert(der, :otp)
    # #'OTPTBSCertificate'.subjectPublicKeyInfo
    {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, _, params}, point} = elem(tbs, 7)
    {point, params}
  end

  # JOSE's r||s back to the DER `SEQUENCE { INTEGER r, INTEGER s }` that
  # :public_key verifies.
  defp raw_to_der(<<r::binary-size(32), s::binary-size(32)>>) do
    body = der_integer(r) <> der_integer(s)
    <<0x30, byte_size(body)>> <> body
  end

  defp der_integer(bin) do
    bin = bin |> :binary.decode_unsigned() |> :binary.encode_unsigned()
    bin = if :binary.first(bin) >= 0x80, do: <<0>> <> bin, else: bin
    <<0x02, byte_size(bin)>> <> bin
  end

  defp expect_alg(%{"alg" => alg}, alg), do: :ok
  defp expect_alg(_, _), do: {:error, :unsupported_alg}

  defp rsa_key(jwks, kid) do
    case Enum.find(jwks, &(&1["kid"] == kid and &1["kty"] == "RSA")) do
      %{"n" => n, "e" => e} ->
        with {:ok, n} <- Base.url_decode64(n, padding: false),
             {:ok, e} <- Base.url_decode64(e, padding: false) do
          {:ok, {:RSAPublicKey, :binary.decode_unsigned(n), :binary.decode_unsigned(e)}}
        else
          _ -> {:error, :unknown_key}
        end

      _ ->
        {:error, :unknown_key}
    end
  end

  defp decode_part(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false),
         {:ok, %{} = map} <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> :error
    end
  end

  # :crypto and :public_key emit DER `SEQUENCE { INTEGER r, INTEGER s }`; JOSE
  # wants r||s, each left-padded to 32 bytes.
  defp der_to_raw(
         <<0x30, _len, 0x02, rlen, r::binary-size(rlen), 0x02, slen, s::binary-size(slen)>>
       ) do
    pad32(r) <> pad32(s)
  end

  defp pad32(int) do
    int = int |> :binary.decode_unsigned() |> :binary.encode_unsigned()
    :binary.copy(<<0>>, 32 - byte_size(int)) <> int
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
