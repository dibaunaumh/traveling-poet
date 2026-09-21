defmodule TravelingPoet.TestChain do
  @moduledoc """
  A root, an intermediate and a leaf certificate made on the spot, and ES256
  tokens signed by the leaf with the chain inside (`x5c`): the shape the App
  Store signs in, without Apple. Pass `root_der` wherever the code under test
  would use Apple's root.
  """

  @doc "`%{root_der, x5c, leaf_key}`"
  def generate do
    ec = {:namedCurve, :secp256r1}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: ec],
          intermediates: [[key: ec]],
          peer: [key: ec]
        },
        client_chain: %{root: [key: ec], intermediates: [[key: ec]], peer: [key: ec]}
      })

    server = data[:server_config]
    leaf = server[:cert]
    {_type, key_der} = server[:key]

    # pkix_test_data spreads the CA certificates over both configs (each side
    # is given what it needs to verify the OTHER), so the leaf's own chain is
    # found by walking issuer links through all of them.
    pool = Enum.uniq(server[:cacerts] ++ data[:client_config][:cacerts])
    intermediate = issuer_of(leaf, pool)
    root = issuer_of(intermediate, pool)
    true = :public_key.pkix_is_self_signed(root)

    %{
      root_der: root,
      x5c: Enum.map([leaf, intermediate, root], &Base.encode64/1),
      leaf_key: :public_key.der_decode(:ECPrivateKey, key_der)
    }
  end

  @doc "A compact ES256 JWS over `claims`, carrying the chain."
  def sign(%{x5c: x5c, leaf_key: key}, claims) do
    header = %{"alg" => "ES256", "x5c" => x5c}
    input = b64(Jason.encode!(header)) <> "." <> b64(Jason.encode!(claims))
    input <> "." <> b64(input |> :public_key.sign(:sha256, key) |> der_to_raw())
  end

  defp issuer_of(cert, pool) do
    Enum.find(pool, fn candidate ->
      candidate != cert and :public_key.pkix_is_issuer(cert, candidate)
    end)
  end

  defp der_to_raw(
         <<0x30, _len, 0x02, rlen, r::binary-size(rlen), 0x02, slen, s::binary-size(slen)>>
       ),
       do: pad32(r) <> pad32(s)

  defp pad32(int) do
    int = int |> :binary.decode_unsigned() |> :binary.encode_unsigned()
    :binary.copy(<<0>>, 32 - byte_size(int)) <> int
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
