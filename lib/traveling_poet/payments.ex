defmodule TravelingPoet.Payments do
  @moduledoc """
  Checkout provider facade. `TravelingPoet.Payments.Stripe` when both Stripe
  secrets are configured, otherwise `TravelingPoet.Payments.Mock` (dev/test —
  an in-app "pay" button that credits the pack immediately, clearly labelled).
  """

  alias TravelingPoet.Accounts.User

  @type pack :: %{id: String.t(), credits: pos_integer(), cents: pos_integer()}
  @type urls :: %{success: String.t(), cancel: String.t()}

  @doc "Returns a URL to send the buyer to."
  @callback start_checkout(User.t(), pack, urls) :: {:ok, String.t()} | {:error, term()}

  def provider, do: Application.get_env(:traveling_poet, :payments_provider, __MODULE__.Mock)

  def mock?, do: provider() == __MODULE__.Mock

  def start_checkout(user, pack, urls), do: provider().start_checkout(user, pack, urls)
end
