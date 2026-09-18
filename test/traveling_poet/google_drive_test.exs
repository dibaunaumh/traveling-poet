defmodule TravelingPoet.GoogleDriveTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, GoogleDrive}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.ChangeStream.Serializer

  @stub TravelingPoet.Google
  @scope "https://www.googleapis.com/auth/drive.file"

  defp creds(attrs \\ %{}) do
    Map.merge(
      %Ueberauth.Auth.Credentials{
        token: "access-1",
        refresh_token: "refresh-1",
        expires_at: System.os_time(:second) + 3600,
        scopes: ["openid", "email", @scope]
      },
      attrs
    )
  end

  defp connected_user(attrs \\ %{}) do
    user = user_fixture()
    {:ok, user} = GoogleDrive.store_credentials(user, creds())
    {:ok, user} = Accounts.update_user(user, attrs)
    user
  end

  # One stub for all of Google: token refresh, folder, resumable upload, revoke.
  defp google(test_pid, overrides \\ %{}) do
    Req.Test.stub(@stub, fn conn ->
      body = Req.Test.raw_body(conn)

      send(
        test_pid,
        {:google, conn.method, conn.host, conn.request_path, conn.query_string, body}
      )

      key = {conn.method, conn.host, conn.request_path}

      case Map.get(overrides, key) do
        fun when is_function(fun, 1) ->
          fun.(conn)

        nil ->
          case key do
            {"POST", "oauth2.googleapis.com", "/token"} ->
              Req.Test.json(conn, %{"access_token" => "access-2", "expires_in" => 3599})

            {"POST", "oauth2.googleapis.com", "/revoke"} ->
              Plug.Conn.send_resp(conn, 200, "")

            {"GET", "www.googleapis.com", "/drive/v3/files/" <> _} ->
              Req.Test.json(conn, %{"id" => "folder-1", "trashed" => false})

            {"POST", "www.googleapis.com", "/drive/v3/files"} ->
              Req.Test.json(conn, %{"id" => "folder-new"})

            {"POST", "www.googleapis.com", "/upload/drive/v3/files"} ->
              conn
              |> Plug.Conn.put_resp_header(
                "location",
                "https://www.googleapis.com/upload/drive/v3/files?upload_id=u1"
              )
              |> Plug.Conn.send_resp(200, "")

            {"PUT", "www.googleapis.com", "/upload/drive/v3/files"} ->
              conn
              |> Plug.Conn.put_status(200)
              |> Req.Test.json(%{
                "id" => "file-9",
                "webViewLink" => "https://drive.google.com/file/d/file-9/view"
              })
          end
      end
    end)
  end

  describe "store_credentials/2" do
    test "keeps the grant, and only a Drive grant with offline access" do
      user = user_fixture()

      assert {:error, :no_drive_scope} =
               GoogleDrive.store_credentials(user, creds(%{scopes: ["email"]}))

      assert {:error, :no_refresh_token} =
               GoogleDrive.store_credentials(user, creds(%{refresh_token: nil}))

      refute GoogleDrive.connected?(Accounts.get_user!(user.id))

      assert {:ok, user} = GoogleDrive.store_credentials(user, creds())
      assert GoogleDrive.connected?(user)
      assert user.google_refresh_token == "refresh-1"
      assert user.drive_connected_at
    end

    test "the consent request asks for drive.file with offline access for this account" do
      params = GoogleDrive.consent_params(%User{email: "udi@example.com", google_scopes: []})
      assert params[:scope] =~ @scope
      assert params[:scope] =~ "email"
      assert params[:access_type] == "offline"
      assert params[:prompt] == "consent"
      assert params[:login_hint] == "udi@example.com"
    end
  end

  describe "upload_pdf/3" do
    test "makes the folder once, uploads resumably, returns the Drive link" do
      user = connected_user()
      google(self())

      assert {:ok, %{id: "file-9", web_link: "https://drive.google.com/file/d/file-9/view"}} =
               GoogleDrive.upload_pdf(user, "%PDF-1.7 book", "Wren - Traveling Poet.pdf")

      assert_receive {:google, "POST", _, "/drive/v3/files", _, folder_body}
      assert folder_body =~ "Traveling Poet"
      assert folder_body =~ "application/vnd.google-apps.folder"

      assert_receive {:google, "POST", _, "/upload/drive/v3/files", query, meta}
      assert query =~ "uploadType=resumable"
      assert meta =~ ~s("parents":["folder-new"])
      assert meta =~ "Wren - Traveling Poet.pdf"

      assert_receive {:google, "PUT", _, "/upload/drive/v3/files", _, "%PDF-1.7 book"}
      assert Accounts.get_user!(user.id).drive_folder_id == "folder-new"
    end

    test "reuses the folder it made, and makes it again when it was trashed" do
      user = connected_user(%{drive_folder_id: "folder-1"})
      google(self())
      assert {:ok, _} = GoogleDrive.upload_pdf(user, "%PDF", "a.pdf")
      refute_received {:google, "POST", _, "/drive/v3/files", _, _}

      user = connected_user(%{drive_folder_id: "folder-old"})

      google(self(), %{
        {"GET", "www.googleapis.com", "/drive/v3/files/folder-old"} =>
          &Req.Test.json(&1, %{"id" => "folder-old", "trashed" => true})
      })

      assert {:ok, _} = GoogleDrive.upload_pdf(user, "%PDF", "a.pdf")
      assert_receive {:google, "POST", _, "/drive/v3/files", _, _}
    end

    test "an expired access token is refreshed first" do
      user =
        connected_user(%{
          google_token_expires_at:
            DateTime.add(DateTime.utc_now(), -10) |> DateTime.truncate(:second)
        })

      google(self())

      assert {:ok, _} = GoogleDrive.upload_pdf(user, "%PDF", "a.pdf")
      assert_receive {:google, "POST", "oauth2.googleapis.com", "/token", _, form}
      assert form =~ "grant_type=refresh_token"
      assert form =~ "refresh_token=refresh-1"
      assert Accounts.get_user!(user.id).google_access_token == "access-2"
    end

    test "a grant revoked in Google asks to reconnect and is forgotten" do
      user =
        connected_user(%{
          google_token_expires_at:
            DateTime.add(DateTime.utc_now(), -10) |> DateTime.truncate(:second)
        })

      google(self(), %{
        {"POST", "oauth2.googleapis.com", "/token"} => fn conn ->
          conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
        end
      })

      assert {:error, :reconnect} = GoogleDrive.upload_pdf(user, "%PDF", "a.pdf")
      refute GoogleDrive.connected?(Accounts.get_user!(user.id))
    end
  end

  test "disconnect revokes with Google and forgets the grant" do
    user = connected_user()
    google(self())

    assert {:ok, user} = GoogleDrive.disconnect(user)
    assert_receive {:google, "POST", "oauth2.googleapis.com", "/revoke", _, form}
    assert form =~ "token=refresh-1"
    refute GoogleDrive.connected?(user)
    assert user.google_access_token == nil
  end

  test "the Drive tokens never leave the app through the change stream" do
    for field <- ~w(google_refresh_token google_access_token) do
      assert Serializer.redacted_field?("users", field)
    end

    refute Serializer.redacted_field?("users", "drive_connected_at")
  end
end
