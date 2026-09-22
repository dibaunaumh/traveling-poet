defmodule TravelingPoetWeb.ReviewLoginController do
  @moduledoc "The App Store reviewer's sign-in; see `TravelingPoetWeb.ReviewLogin`."
  use TravelingPoetWeb, :controller

  alias TravelingPoetWeb.{ReviewLogin, SignIn}

  plug :require_enabled

  def new(conn, _params) do
    conn
    |> assign(:page_title, "Reviewer sign-in")
    |> render(:new, error: nil)
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case ReviewLogin.authenticate(email, password) do
      {:ok, user} ->
        SignIn.establish(conn, user, nil)

      {:error, :throttled} ->
        conn
        |> put_status(429)
        |> render(:new, error: "Too many attempts. Please wait a quarter of an hour.")

      {:error, _} ->
        conn
        |> put_status(401)
        |> render(:new, error: "That email and password do not match.")
    end
  end

  def create(conn, _params), do: redirect(conn, to: ~p"/auth/review")

  # Unset secrets mean this door does not exist at all.
  defp require_enabled(conn, _opts) do
    if ReviewLogin.enabled?() do
      conn
    else
      conn |> put_status(404) |> put_view(TravelingPoetWeb.ErrorHTML) |> render(:"404") |> halt()
    end
  end
end
