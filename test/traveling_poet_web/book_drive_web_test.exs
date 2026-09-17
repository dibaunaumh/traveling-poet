defmodule TravelingPoetWeb.BookDriveWebTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Books, GoogleDrive, Journal, Poets}
  alias TravelingPoet.Books.PdfRenderer
  alias TravelingPoetWeb.AuthController

  @scope "https://www.googleapis.com/auth/drive.file"

  setup do
    Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
    on_exit(fn -> Application.delete_env(:traveling_poet, :sprites_client) end)

    user = agent_user_fixture(%{onboarding_completed: true, google_id: "google-udi"})
    {:ok, user} = Accounts.update_user(user, %{sprite_name: "sandbox-drive-#{user.id}"})
    poet = poet_fixture(user, %{name: "Wren"})
    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
    entry = published_entry_fixture(poet)
    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "Hills."}])
    {:ok, pdf} = Books.request_pdf(user, poet)
    pdf = PdfRenderer.run(pdf.id)

    Req.Test.stub(TravelingPoet.GoogleDrive, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/drive/v3/files"} ->
          Req.Test.json(conn, %{"id" => "folder-1"})

        {"POST", "/upload/drive/v3/files"} ->
          conn
          |> Plug.Conn.put_resp_header(
            "location",
            "https://www.googleapis.com/upload/drive/v3/files?upload_id=u"
          )
          |> Plug.Conn.send_resp(200, "")

        {"PUT", "/upload/drive/v3/files"} ->
          Req.Test.json(conn, %{
            "id" => "file-1",
            "webViewLink" => "https://drive.google.com/file/d/file-1/view"
          })

        {"POST", "/revoke"} ->
          Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    %{user: user, poet: poet, pdf: pdf}
  end

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp google_auth(uid, scopes) do
    %Ueberauth.Auth{
      provider: :google,
      uid: uid,
      info: %Ueberauth.Auth.Info{email: "udi@example.com", name: "Udi"},
      credentials: %Ueberauth.Auth.Credentials{
        token: "access-1",
        refresh_token: "refresh-1",
        expires_at: System.os_time(:second) + 3600,
        scopes: scopes
      }
    }
  end

  defp callback(session, auth) do
    build_conn()
    |> Plug.Test.init_test_session(session)
    |> Phoenix.ConnTest.fetch_flash()
    |> Plug.Conn.assign(:ueberauth_auth, auth)
    |> AuthController.callback(%{})
  end

  test "connect parks the intent and asks Google for drive.file on top of sign-in",
       %{conn: conn, user: user, pdf: pdf} do
    conn = conn |> signed_in(user) |> get(~p"/journal/book/drive/connect?#{[pdf: pdf.id]}")
    location = redirected_to(conn)
    assert location =~ "/auth/google?"
    query = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    assert query["scope"] =~ @scope
    assert query["access_type"] == "offline"

    assert get_session(conn, :drive_connect) == %{
             "pdf" => Integer.to_string(pdf.id),
             "user_id" => user.id
           }
  end

  test "back from Google with the same account: grant kept, the PDF saved to Drive", %{
    user: user,
    pdf: pdf
  } do
    conn =
      callback(
        %{
          user_id: user.id,
          drive_connect: %{"pdf" => Integer.to_string(pdf.id), "user_id" => user.id}
        },
        google_auth("google-udi", ["email", @scope])
      )

    assert redirected_to(conn) == "/settings#book"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Saving your PDF there now"
    assert get_session(conn, :drive_connect) == nil
    assert GoogleDrive.connected?(Accounts.get_user!(user.id))

    # the save runs inline in test
    Books.run_drive_save(user.id, pdf.id)
    saved = Books.get_pdf(pdf.id)
    assert saved.drive_status == "saved"
    assert saved.drive_web_link == "https://drive.google.com/file/d/file-1/view"
  end

  test "a different Google account on the consent screen changes nothing", %{user: user, pdf: pdf} do
    conn =
      callback(
        %{
          user_id: user.id,
          drive_connect: %{"pdf" => Integer.to_string(pdf.id), "user_id" => user.id}
        },
        google_auth("google-someone-else", ["email", @scope])
      )

    assert redirected_to(conn) == "/settings#book"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Google account you sign in with"
    # still signed in as the same person, and no grant kept
    assert get_session(conn, :user_id) == user.id
    refute GoogleDrive.connected?(Accounts.get_user!(user.id))
    assert Books.get_pdf(pdf.id).drive_status == nil
  end

  test "Drive unticked on the consent screen saves nothing", %{user: user, pdf: pdf} do
    conn =
      callback(
        %{
          user_id: user.id,
          drive_connect: %{"pdf" => Integer.to_string(pdf.id), "user_id" => user.id}
        },
        google_auth("google-udi", ["email"])
      )

    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not allowed"
    refute GoogleDrive.connected?(Accounts.get_user!(user.id))
  end

  test "an ordinary sign-in is untouched by any of this", %{user: user} do
    conn = callback(%{}, google_auth("google-udi", ["email"]))
    assert get_session(conn, :user_id) == user.id
    assert redirected_to(conn) == "/journal"
    refute GoogleDrive.connected?(Accounts.get_user!(user.id))
  end

  test "Settings: not connected sends you to connect; connected saves and links to Drive; disconnect forgets",
       %{conn: conn, user: user, pdf: pdf} do
    {:ok, view, html} = live(signed_in(conn, user), ~p"/settings")
    assert html =~ "Save to Google Drive"

    assert {:error, {:redirect, %{to: to}}} =
             view |> element("#drive-save-button") |> render_click()

    assert to == "/journal/book/drive/connect?pdf=#{pdf.id}"

    {:ok, user} =
      GoogleDrive.store_credentials(
        user,
        google_auth("google-udi", ["email", @scope]).credentials
      )

    {:ok, view, _html} = live(signed_in(build_conn(), user), ~p"/settings")
    html = view |> element("#drive-save-button") |> render_click()
    assert html =~ "Saving to Google Drive"

    Books.run_drive_save(user.id, pdf.id)
    html = render(view)
    assert html =~ ~s(id="drive-open")
    assert html =~ "https://drive.google.com/file/d/file-1/view"

    html = view |> element("#disconnect-drive") |> render_click()
    assert html =~ "Google Drive disconnected"
    refute GoogleDrive.connected?(Accounts.get_user!(user.id))
  end

  test "a grant gone since shows a reconnect link, not a retry", %{
    conn: conn,
    user: user,
    pdf: pdf
  } do
    {:ok, _} =
      pdf
      |> TravelingPoet.Books.Pdf.changeset(%{drive_status: "failed", drive_error: "reconnect"})
      |> TravelingPoet.Repo.update()

    {:ok, _view, html} = live(signed_in(conn, user), ~p"/settings")
    assert html =~ ~s(id="drive-reconnect")
    refute html =~ ~s(id="drive-save-button")
  end
end
