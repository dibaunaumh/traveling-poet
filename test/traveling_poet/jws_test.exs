defmodule TravelingPoet.JWSTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.JWS

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  # An ES256 signature as JOSE carries it (r||s) back to the DER :crypto wants
  defp raw_to_der(<<r::binary-size(32), s::binary-size(32)>>) do
    int = fn bin ->
      bin = bin |> :binary.decode_unsigned() |> :binary.encode_unsigned()
      bin = if :binary.first(bin) >= 0x80, do: <<0>> <> bin, else: bin
      <<0x02, byte_size(bin)>> <> bin
    end

    body = int.(r) <> int.(s)
    <<0x30, byte_size(body)>> <> body
  end

  defp es256_valid?(jwt, public) do
    [h, c, sig] = String.split(jwt, ".")
    der = sig |> Base.url_decode64!(padding: false) |> raw_to_der()
    :crypto.verify(:ecdsa, :sha256, h <> "." <> c, der, [public, :prime256v1])
  end

  describe "sign_es256/3" do
    test "with a raw scalar, as Web Push keys come" do
      {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
      jwt = JWS.sign_es256(%{"typ" => "JWT"}, %{"sub" => "mailto:a@b.c"}, {:raw, private})

      assert {:ok, %{"alg" => "ES256", "typ" => "JWT"}, %{"sub" => "mailto:a@b.c"}} =
               JWS.peek(jwt)

      assert es256_valid?(jwt, public)
    end

    test "with a PKCS#8 PEM, as Apple's .p8 keys come" do
      # what `openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256` writes
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      public = elem(key, 4)
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, key)])
      assert pem =~ "BEGIN PRIVATE KEY"

      jwt = JWS.sign_es256(%{"kid" => "KEY123"}, %{"iss" => "TEAM"}, {:pem, pem})

      assert {:ok, %{"alg" => "ES256", "kid" => "KEY123"}, %{"iss" => "TEAM"}} = JWS.peek(jwt)
      assert es256_valid?(jwt, public)
    end

    test "signatures are always 64 bytes, whatever r and s came out as" do
      {_public, private} = :crypto.generate_key(:ecdh, :prime256v1)

      for n <- 1..40 do
        [_, _, sig] = %{} |> JWS.sign_es256(%{"n" => n}, {:raw, private}) |> String.split(".")
        assert byte_size(Base.url_decode64!(sig, padding: false)) == 64
      end
    end
  end

  describe "verify_rs256/2" do
    setup do
      key = :public_key.generate_key({:rsa, 2048, 65_537})
      {:RSAPrivateKey, _, n, e, _, _, _, _, _, _, _} = key

      jwk = %{
        "kty" => "RSA",
        "kid" => "apple-1",
        "alg" => "RS256",
        "n" => b64(:binary.encode_unsigned(n)),
        "e" => b64(:binary.encode_unsigned(e))
      }

      sign = fn header, claims ->
        input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
        input <> "." <> b64(:public_key.sign(input, :sha256, key))
      end

      %{jwk: jwk, sign: sign}
    end

    test "returns the claims of a token signed by a published key", %{jwk: jwk, sign: sign} do
      token = sign.(%{"alg" => "RS256", "kid" => "apple-1"}, %{"sub" => "001.abc"})
      other = Map.put(jwk, "kid", "apple-0")

      assert {:ok, %{"sub" => "001.abc"}} = JWS.verify_rs256(token, [other, jwk])
    end

    test "refuses a tampered payload, an unknown key, and another key's signature",
         %{jwk: jwk, sign: sign} do
      token = sign.(%{"alg" => "RS256", "kid" => "apple-1"}, %{"sub" => "001.abc"})
      [h, _c, s] = String.split(token, ".")
      forged = Enum.join([h, b64(Jason.encode!(%{"sub" => "001.someone-else"})), s], ".")

      assert {:error, :bad_signature} = JWS.verify_rs256(forged, [jwk])
      assert {:error, :unknown_key} = JWS.verify_rs256(token, [Map.put(jwk, "kid", "rotated")])
      assert {:error, :unknown_key} = JWS.verify_rs256(token, [])

      stranger = :public_key.generate_key({:rsa, 2048, 65_537})
      input = h <> "." <> b64(Jason.encode!(%{"sub" => "001.abc"}))
      imposter = input <> "." <> b64(:public_key.sign(input, :sha256, stranger))
      assert {:error, :bad_signature} = JWS.verify_rs256(imposter, [jwk])
    end

    test "refuses a token that names any other algorithm", %{jwk: jwk, sign: sign} do
      for alg <- ["none", "HS256", "ES256"] do
        token = sign.(%{"alg" => alg, "kid" => "apple-1"}, %{"sub" => "001.abc"})
        assert {:error, :unsupported_alg} = JWS.verify_rs256(token, [jwk])
      end
    end

    test "refuses what is not a token at all", %{jwk: jwk} do
      for junk <- ["", "a.b", "a.b.c", "....", nil, 42] do
        assert {:error, :malformed} = JWS.verify_rs256(junk, [jwk])
      end
    end
  end
end

defmodule TravelingPoet.JWSChainTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.JWS
  alias TravelingPoet.TestChain

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  describe "verify_es256_x5c/3" do
    test "trusts a token whose chain leads to the root we hold" do
      chain = TestChain.generate()
      token = TestChain.sign(chain, %{"transactionId" => "2000000123"})

      assert {:ok, %{"transactionId" => "2000000123"}} =
               JWS.verify_es256_x5c(token, chain.root_der)
    end

    test "a chain to somebody else's root is worth nothing, however valid it is" do
      ours = TestChain.generate()
      theirs = TestChain.generate()
      forged = TestChain.sign(theirs, %{"transactionId" => "free-credits"})

      assert {:ok, _} = JWS.verify_es256_x5c(forged, theirs.root_der)
      assert {:error, :untrusted_chain} = JWS.verify_es256_x5c(forged, ours.root_der)
    end

    test "the payload cannot be changed, and the leaf cannot be swapped under it" do
      chain = TestChain.generate()
      token = TestChain.sign(chain, %{"productId" => "p10"})
      [h, _c, s] = String.split(token, ".")

      tampered = Enum.join([h, b64(Jason.encode!(%{"productId" => "p300"})), s], ".")
      assert {:error, :bad_signature} = JWS.verify_es256_x5c(tampered, chain.root_der)

      # signed with another key, presented under the genuine chain
      other = TestChain.generate()
      imposter = TestChain.sign(%{chain | leaf_key: other.leaf_key}, %{"productId" => "p300"})
      assert {:error, :bad_signature} = JWS.verify_es256_x5c(imposter, chain.root_der)
    end

    test "required certificate markers must be present" do
      chain = TestChain.generate()
      token = TestChain.sign(chain, %{"n" => 1})
      marker = {1, 2, 840, 113_635, 100, 6, 11, 1}

      assert {:error, :untrusted_chain} =
               JWS.verify_es256_x5c(token, chain.root_der, require_oids: [leaf: marker])

      # basicConstraints is on every CA certificate, the intermediate included
      assert {:ok, _} =
               JWS.verify_es256_x5c(token, chain.root_der,
                 require_oids: [intermediate: {2, 5, 29, 19}]
               )
    end

    test "refuses other algorithms, missing chains and junk" do
      chain = TestChain.generate()
      [_h, c, s] = chain |> TestChain.sign(%{"n" => 1}) |> String.split(".")

      none = Enum.join([b64(Jason.encode!(%{"alg" => "none", "x5c" => chain.x5c})), c, s], ".")
      assert {:error, :unsupported_alg} = JWS.verify_es256_x5c(none, chain.root_der)

      no_chain = Enum.join([b64(Jason.encode!(%{"alg" => "ES256"})), c, s], ".")
      assert {:error, :bad_chain} = JWS.verify_es256_x5c(no_chain, chain.root_der)

      bad_chain =
        Enum.join([b64(Jason.encode!(%{"alg" => "ES256", "x5c" => ["@@", "@@"]})), c, s], ".")

      assert {:error, :bad_chain} = JWS.verify_es256_x5c(bad_chain, chain.root_der)

      assert {:error, :malformed} = JWS.verify_es256_x5c("not.a.token", chain.root_der)
    end
  end
end
