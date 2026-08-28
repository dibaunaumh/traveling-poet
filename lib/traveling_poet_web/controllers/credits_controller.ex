defmodule TravelingPoetWeb.CreditsController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Credits, Payments}
  alias TravelingPoet.Payments.Mock

  @doc "POST /credits/checkout — sends the buyer to the provider's checkout."
  def checkout(conn, %{"pack" => pack_id}) do
    user = conn.assigns.current_user

    case Credits.pack(pack_id) do
      nil ->
        conn |> put_flash(:error, "Unknown credit pack.") |> redirect(to: ~p"/settings")

      pack ->
        urls = %{success: url(~p"/settings?purchased=1"), cancel: url(~p"/settings")}

        case Payments.start_checkout(user, pack, urls) do
          {:ok, "/" <> _ = path} ->
            redirect(conn, to: path)

          {:ok, url} ->
            redirect(conn, external: url)

          {:error, reason} ->
            require Logger
            Logger.error("checkout failed for user #{user.id}: #{inspect(reason)}")

            conn
            |> put_flash(:error, "Checkout is unavailable right now.")
            |> redirect(to: ~p"/settings")
        end
    end
  end

  def checkout(conn, _), do: redirect(conn, to: ~p"/settings")

  @doc "GET /credits/mock-checkout — the MOCK pay page (never live with Stripe)."
  def mock_checkout(conn, %{"token" => token}) do
    with true <- Payments.mock?(),
         {:ok, pack_id} <- Mock.verify(token, conn.assigns.current_user.id),
         pack when not is_nil(pack) <- Credits.pack(pack_id) do
      render(conn, :mock_checkout, pack: pack, token: token)
    else
      _ ->
        conn
        |> put_flash(:error, "That checkout link is invalid or expired.")
        |> redirect(to: ~p"/settings")
    end
  end

  def mock_checkout(conn, _), do: redirect(conn, to: ~p"/settings")

  @doc "POST /credits/mock-checkout/confirm — credits the pack once per token."
  def mock_confirm(conn, %{"token" => token}) do
    user = conn.assigns.current_user

    with true <- Payments.mock?(),
         {:ok, pack_id} <- Mock.verify(token, user.id),
         {:ok, _} <- Credits.purchase(user, pack_id, Mock.reference(token)) do
      redirect(conn, to: ~p"/settings?purchased=1")
    else
      _ -> conn |> put_flash(:error, "Mock payment failed.") |> redirect(to: ~p"/settings")
    end
  end

  def mock_confirm(conn, _), do: redirect(conn, to: ~p"/settings")
end
