defmodule TravelingPoetWeb.AuthController do
  use TravelingPoetWeb, :controller
  plug Ueberauth

  alias TravelingPoet.{Accounts, Analytics, Books, GoogleAuth}
  alias TravelingPoetWeb.{NativeAuth, SignIn, UserAuth}

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
    google_connect = get_session(conn, :google_connect)

    # Set when this request is running in the iOS app's sign-in sheet rather
    # than a browser: the answer then goes back to the app, not into this
    # session (see NativeAuth).
    native = get_session(conn, :native_auth)
    conn = delete_session(conn, :native_auth)

    if google_connect do
      connect_google(conn, auth, user_info, google_connect, native)
    else
      sign_in(conn, user_info, start_place, native)
    end
  end

  def callback(%{assigns: %{ueberauth_failure: _fails}} = conn, _params) do
    native = get_session(conn, :native_auth)
    conn = conn |> delete_session(:google_connect) |> delete_session(:native_auth)

    if native do
      redirect(conn, external: NativeAuth.failed_url())
    else
      conn
      |> put_flash(:error, "Failed to authenticate.")
      |> redirect(to: "/")
    end
  end

  # Back from Google with a feature (Drive, Calendar) asked for on top of
  # sign-in. This is not a sign-in: a different Google account picked on the
  # consent screen must not switch who is signed in, and its grant is not
  # kept.
  defp connect_google(conn, auth, user_info, %{"user_id" => user_id} = intent, native) do
    conn = delete_session(conn, :google_connect)
    feature = feature(intent["feature"])
    current = Accounts.get_user(user_id)

    cond do
      is_nil(feature) and native ->
        redirect(conn, external: NativeAuth.failed_url())

      is_nil(feature) ->
        conn |> put_flash(:error, "Failed to authenticate.") |> redirect(to: ~p"/settings")

      is_nil(current) or current.google_id != user_info["sub"] ->
        finish_connect(conn, native, feature, "wrong_account")

      true ->
        case GoogleAuth.store_credentials(current, auth.credentials, feature) do
          {:ok, user} -> finish_connect(conn, native, feature, connected(feature, user, intent))
          {:error, :scope_not_granted} -> finish_connect(conn, native, feature, "not_allowed")
          {:error, _} -> finish_connect(conn, native, feature, "failed")
        end
    end
  end

  # How a connect attempt ends. A browser gets a flash on the page it came
  # from. The iOS app's sheet is sent back to the app with the outcome as a
  # code, because a flash set in the sheet's session would never be seen;
  # the page the app opens next turns the code into the same words
  # (NativeAuth.connect_notice/1).
  defp finish_connect(conn, nil, feature, notice) do
    {kind, text} = NativeAuth.connect_notice("#{feature}:#{notice}")
    conn |> put_flash(kind, text) |> redirect(to: return_to(feature))
  end

  defp finish_connect(conn, _native, feature, notice) do
    redirect(conn, external: NativeAuth.connected_url(return_to(feature), feature, notice))
  end

  defp feature("drive"), do: :drive
  defp feature("calendar"), do: :calendar
  defp feature(_), do: nil

  defp return_to(:drive), do: ~p"/settings#book"
  defp return_to(:calendar), do: ~p"/settings#trips"

  # Calendar connected: look for trips straight away.
  defp connected(:calendar, user, _intent) do
    TravelingPoet.Trips.CalendarSync.sync_soon(user)
    "ok"
  end

  # Drive connected with a PDF in hand: start saving it straight away.
  defp connected(:drive, user, intent) do
    with {id, ""} <- Integer.parse(to_string(intent["pdf"])),
         %{} = pdf <- Books.get_owned_pdf(user, id),
         {:ok, _} <- Books.save_pdf_to_drive(user, pdf) do
      "ok_saving"
    else
      _ -> "ok"
    end
  end

  defp sign_in(conn, user_info, start_place, native) do
    new? = is_nil(Accounts.get_user_by_google_id(user_info["sub"]))

    case Accounts.find_or_create_from_oauth(:google, user_info) do
      {:ok, user} ->
        # Joins today's anonymous visit to the account (see Analytics).
        Analytics.record(%{
          name: if(new?, do: "signup", else: "login"),
          visitor: Analytics.visitor_id(conn),
          user_id: user.id
        })

        case native do
          # The app's sheet: this session is Safari's and stays signed out.
          # The app trades the token for a session of its own.
          %{"challenge" => challenge} ->
            redirect(conn,
              external: NativeAuth.signed_in_url(NativeAuth.handoff_token(user.id, challenge))
            )

          nil ->
            SignIn.establish(conn, user, start_place, user_info["name"])

          _ ->
            redirect(conn, external: NativeAuth.failed_url())
        end

      {:error, _changeset} when not is_nil(native) ->
        redirect(conn, external: NativeAuth.failed_url())

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
end
