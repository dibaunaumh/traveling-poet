defmodule TravelingPoetWeb.DevSessionController do
  @moduledoc """
  Dev-only sign-in without Google, for looking at owner pages locally:
  `GET /dev/login/:user_id` starts a session for that user and lands on the
  journal. Routed only under `config :traveling_poet, dev_routes: true`, so
  it never exists in a release.
  """

  use TravelingPoetWeb, :controller

  alias TravelingPoet.Accounts
  alias TravelingPoetWeb.UserAuth

  def login(conn, %{"user_id" => id}) do
    case Accounts.get_user(id) do
      nil ->
        conn |> put_status(:not_found) |> text("no such user")

      user ->
        conn
        |> UserAuth.log_in_user(user)
        |> redirect(to: ~p"/journal")
    end
  end
end
