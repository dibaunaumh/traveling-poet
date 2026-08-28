defmodule TravelingPoet.Payments.Mock do
  @moduledoc """
  Fake checkout for dev/test: hands the buyer a signed token for the pack;
  `/credits/mock-checkout` shows a MOCK pay page that credits it. Never the
  provider when Stripe is configured (see config/runtime.exs).
  """

  @behaviour TravelingPoet.Payments

  @salt "mock-checkout"
  @max_age 600

  @impl true
  def start_checkout(user, pack, _urls) do
    {:ok, "/credits/mock-checkout?token=#{sign(user.id, pack.id)}"}
  end

  def sign(user_id, pack_id) do
    Phoenix.Token.sign(TravelingPoetWeb.Endpoint, @salt, {user_id, pack_id})
  end

  @doc "Verifies a token for this user: `{:ok, pack_id}` or `{:error, reason}`."
  def verify(token, user_id) do
    case Phoenix.Token.verify(TravelingPoetWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, {^user_id, pack_id}} -> {:ok, pack_id}
      {:ok, _other} -> {:error, :wrong_user}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Idempotency reference for a token: one token credits at most once."
  def reference(token) do
    "mock:" <> (:crypto.hash(:sha256, token) |> Base.encode16(case: :lower) |> binary_part(0, 32))
  end
end
