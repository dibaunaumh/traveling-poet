defmodule TravelingPoetWeb.AuthController do
  use TravelingPoetWeb, :controller
  plug Ueberauth

  alias TravelingPoet.{Accounts, Books, GoogleDrive}
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
    drive_connect = get_session(conn, :drive_connect)

    if drive_connect do
      connect_drive(conn, auth, user_info, drive_connect)
    else
      sign_in(conn, user_info, start_place)
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _fails}} = conn, _params) do
    conn
    |> delete_session(:drive_connect)
    |> put_flash(:error, "Failed to authenticate.")
    |> redirect(to: "/")
  end

  # Back from Google with Drive access asked for. This is not a sign-in: a
  # different Google account picked on the consent screen must not switch
  # who is signed in, and its grant is not kept.
  defp connect_drive(conn, auth, user_info, %{"user_id" => user_id} = intent) do
    conn = delete_session(conn, :drive_connect)
    current = Accounts.get_user(user_id)

    cond do
      is_nil(current) or current.google_id != user_info["sub"] ->
        conn
        |> put_flash(:error, "Please choose the Google account you sign in with.")
        |> redirect(to: ~p"/settings#book")

      true ->
        case GoogleDrive.store_credentials(current, auth.credentials) do
          {:ok, user} ->
            conn
            |> put_flash(:info, drive_connected_note(user, intent["pdf"]))
            |> redirect(to: ~p"/settings#book")

          {:error, :no_drive_scope} ->
            conn
            |> put_flash(:error, "Google Drive was not allowed, so nothing was saved.")
            |> redirect(to: ~p"/settings#book")

          {:error, _} ->
            conn
            |> put_flash(:error, "Google did not grant Drive access. Please try again.")
            |> redirect(to: ~p"/settings#book")
        end
    end
  end

  # Connected with a PDF in hand: start saving it straight away.
  defp drive_connected_note(user, pdf_id) do
    with {id, ""} <- Integer.parse(to_string(pdf_id)),
         %{} = pdf <- Books.get_owned_pdf(user, id),
         {:ok, _} <- Books.save_pdf_to_drive(user, pdf) do
      "Connected to Google Drive. Saving your PDF there now."
    else
      _ -> "Connected to Google Drive."
    end
  end

  defp sign_in(conn, user_info, start_place) do
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
