defmodule TravelingPoetWeb.Plugs.Referral do
  @moduledoc """
  Parks an invite code (`?ref=CODE` on any page) in the session of someone
  signed out, so `UserAuth.log_in_user/2` can claim it when they sign up
  (card-126). An owner's shared pages carry their code this way, which makes
  every shared page an invite.

  Only the code's shape is checked here; whether it belongs to anyone is
  `TravelingPoet.Referrals.claim/2`'s business. The newest code wins, the way
  a friend's latest link would be the one they meant.
  """

  import Plug.Conn

  alias TravelingPoet.Referrals

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %{}}} = conn, _opts), do: conn

  def call(conn, _opts) do
    case Referrals.normalize(conn.params["ref"]) do
      nil -> conn
      code -> put_session(conn, :referral_code, code)
    end
  end
end
