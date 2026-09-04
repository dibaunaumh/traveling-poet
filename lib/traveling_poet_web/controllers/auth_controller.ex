defmodule TravelingPoetWeb.AuthController do
  use TravelingPoetWeb, :controller
  plug Ueberauth

  alias TravelingPoet.Accounts
  alias TravelingPoetWeb.UserAuth

  @doc """
  Initiates the OAuth flow (Ueberauth handles the redirect).
  """
  def request(conn, _params) do
    conn
  end

  @doc """
  Handles OAuth callbacks. Google is the login provider (find-or-create +
  session). Apple slots in later as another clause dispatching on
  `auth.provider`.
  """
  def callback(%{assigns: %{ueberauth_auth: %{provider: :google} = auth}} = conn, _params) do
    user_info = %{
      "sub" => auth.uid,
      "email" => auth.info.email,
      "name" => auth.info.name
    }

    # Parked by the home page's destination box; log_in_user clears the
    # session, so read it first.
    start_place = get_session(conn, :start_place)

    case Accounts.find_or_create_from_oauth(:google, user_info) do
      {:ok, user} ->
        name = user_info["name"] || user.name || "there"

        conn
        |> UserAuth.log_in_user(user)
        |> put_flash(:info, "Welcome, #{name}!")
        |> redirect_after_login(user, start_place)

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Failed to authenticate. Please try again.")
        |> redirect(to: "/")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _fails}} = conn, _params) do
    conn
    |> put_flash(:error, "Failed to authenticate.")
    |> redirect(to: "/")
  end

  @doc """
  Logs out the user.
  """
  def logout(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp redirect_after_login(conn, user, start_place) do
    if user.onboarding_completed do
      redirect(conn, to: ~p"/journal")
    else
      redirect(conn, to: TravelingPoetWeb.PageController.onboarding_path(start_place))
    end
  end
end
