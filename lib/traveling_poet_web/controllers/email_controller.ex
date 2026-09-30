defmodule TravelingPoetWeb.EmailController do
  @moduledoc """
  Stopping the daily page email. The link in every email opens a page with
  one button (opening a link must not unsubscribe: mail scanners open them);
  the button, and a mail app's own one-click button (RFC 8058,
  `List-Unsubscribe-Post`), POST to the same token URL. The token is the
  authorization, so that POST sits outside CSRF.
  """

  use TravelingPoetWeb, :controller

  alias TravelingPoet.Accounts
  alias TravelingPoet.Email.Notifier

  def show(conn, %{"token" => token}) do
    case Notifier.verify_unsubscribe(token) do
      {:ok, _user_id} -> render(conn, :unsubscribe, token: token)
      _ -> conn |> put_status(404) |> render(:invalid)
    end
  end

  def unsubscribe(conn, %{"token" => token}) do
    with {:ok, user_id} <- Notifier.verify_unsubscribe(token),
         %{} = user <- Accounts.get_user(user_id),
         {:ok, _} <- Accounts.update_user(user, %{email_notify: false}) do
      redirect(conn, to: ~p"/email/unsubscribed")
    else
      _ -> send_resp(conn, 404, "not found")
    end
  end

  def done(conn, _params), do: render(conn, :done)
end
