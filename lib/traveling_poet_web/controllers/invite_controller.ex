defmodule TravelingPoetWeb.InviteController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.Referrals

  @doc """
  A reader's invite link, `/i/:code` (card-126). Someone signed out keeps the
  code in their session and lands on the home page, which names the friend
  who invited them; a reader already signed in just goes home, since a code
  is only for new readers.
  """
  def show(conn, %{"code" => code}) do
    case {conn.assigns[:current_user], Referrals.normalize(code)} do
      {nil, code} when is_binary(code) ->
        conn
        |> put_session(:referral_code, code)
        |> redirect(to: ~p"/")

      _ ->
        redirect(conn, to: ~p"/")
    end
  end
end
