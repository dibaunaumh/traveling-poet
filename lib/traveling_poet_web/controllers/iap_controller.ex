defmodule TravelingPoetWeb.IapController do
  @moduledoc """
  Where the iOS app posts a StoreKit transaction to be credited; see
  `TravelingPoet.Payments.AppleIAP`.

  A controller rather than a LiveView event, because a purchase can outlive
  the page it was made on: StoreKit redelivers anything unfinished at the
  next launch, whatever page the app opens on, and `native.js` posts it here
  from there. `finish` in the answer tells the app whether to close the
  transaction with StoreKit.
  """
  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.{Accounts, Credits}
  alias TravelingPoet.Payments.AppleIAP

  def create(conn, %{"jws" => jws}) do
    user = conn.assigns.current_user

    case AppleIAP.fulfil(user, jws) do
      {:ok, outcome} ->
        balance = Accounts.get_user!(user.id).credits_balance || 0

        json(conn, %{
          status: Atom.to_string(outcome),
          finish: true,
          balance: Credits.format(balance)
        })

      # Bought under a different account on this phone: leave it for that
      # account, which will be credited and finish it when it is signed in.
      {:error, :wrong_account} ->
        conn |> put_status(409) |> json(%{status: "wrong_account", finish: false})

      {:error, reason} ->
        Logger.warning("IAP: transaction refused for user #{user.id}: #{inspect(reason)}")
        conn |> put_status(422) |> json(%{status: "refused", finish: false})
    end
  end

  def create(conn, _params),
    do: conn |> put_status(400) |> json(%{status: "refused", finish: false})
end
