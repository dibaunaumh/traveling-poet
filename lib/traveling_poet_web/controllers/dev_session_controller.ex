defmodule TravelingPoetWeb.DevSessionController do
  @moduledoc """
  Dev-only sign-in without Google, for looking at owner pages locally:
  `GET /dev/login/:user_id` starts a session for that user and lands on the
  journal (or on `?to=`, a local path). Routed only under `config :traveling_poet, dev_routes: true`, so
  it never exists in a release.
  """

  use TravelingPoetWeb, :controller

  alias TravelingPoet.Accounts
  alias TravelingPoetWeb.UserAuth

  def login(conn, %{"user_id" => id} = params) do
    case Accounts.get_user(id) do
      nil ->
        conn |> put_status(:not_found) |> text("no such user")

      user ->
        conn
        |> UserAuth.log_in_user(user)
        |> redirect(to: destination(params["to"]))
    end
  end

  # `?to=/journal/book` lands somewhere else in the app (a headless browser
  # printing the book locally has no other way in). Local paths only.
  defp destination("/" <> rest = path) do
    if String.starts_with?(rest, "/"), do: ~p"/journal", else: path
  end

  defp destination(_), do: ~p"/journal"
end
