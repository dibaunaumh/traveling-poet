defmodule TravelingPoet.GoogleAuthTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, GoogleAuth, GoogleDrive}
  alias TravelingPoet.ChangeStream.Serializer

  @stub TravelingPoet.Google
  @drive "https://www.googleapis.com/auth/drive.file"
  @calendar "https://www.googleapis.com/auth/calendar.events.readonly"

  defp creds(attrs \\ %{}) do
    Map.merge(
      %Ueberauth.Auth.Credentials{
        token: "access-1",
        refresh_token: "refresh-1",
        expires_at: System.os_time(:second) + 3600,
        scopes: ["openid", "email", @drive]
      },
      attrs
    )
  end

  defp google(test_pid) do
    Req.Test.stub(@stub, fn conn ->
      body = Req.Test.raw_body(conn)
      send(test_pid, {:google, conn.method, conn.host, conn.request_path, body})

      case {conn.method, conn.host, conn.request_path} do
        {"POST", "oauth2.googleapis.com", "/token"} ->
          Req.Test.json(conn, %{"access_token" => "access-2", "expires_in" => 3599})

        {"POST", "oauth2.googleapis.com", "/revoke"} ->
          Plug.Conn.send_resp(conn, 200, "")
      end
    end)
  end

  defp drive_user do
    {:ok, user} = GoogleAuth.store_credentials(user_fixture(), creds(), :drive)
    user
  end

  describe "consent_params/2" do
    test "asks for the feature on top of sign-in, keeping every scope already held" do
      user = user_fixture()
      params = GoogleAuth.consent_params(user, :drive)
      assert params[:scope] == "email profile #{@drive}"
      assert params[:access_type] == "offline"
      assert params[:prompt] == "consent"
      assert params[:login_hint] == user.email

      params = GoogleAuth.consent_params(drive_user(), :calendar)
      assert params[:scope] == "email profile #{@drive} #{@calendar}"
    end
  end

  describe "store_credentials/3" do
    test "keeps exactly the feature scopes the new token carries" do
      user = user_fixture()

      assert {:error, :scope_not_granted} =
               GoogleAuth.store_credentials(user, creds(%{scopes: ["email"]}), :drive)

      assert {:error, :no_refresh_token} =
               GoogleAuth.store_credentials(user, creds(%{refresh_token: nil}), :drive)

      refute GoogleAuth.connected?(Accounts.get_user!(user.id), :drive)

      assert {:ok, user} = GoogleAuth.store_credentials(user, creds(), :drive)
      assert GoogleAuth.connected?(user, :drive)
      refute GoogleAuth.connected?(user, :calendar)
      assert user.google_scopes == [@drive]
      assert user.google_refresh_token == "refresh-1"
      assert user.drive_connected_at
    end

    test "a second feature joins the grant without losing the first" do
      user = drive_user()
      drive_connected_at = user.drive_connected_at

      assert {:ok, user} =
               GoogleAuth.store_credentials(
                 user,
                 creds(%{refresh_token: "refresh-2", scopes: ["email", @drive, @calendar]}),
                 :calendar
               )

      assert GoogleAuth.connected?(user, :drive)
      assert GoogleAuth.connected?(user, :calendar)
      assert user.google_scopes == [@drive, @calendar]
      assert user.google_refresh_token == "refresh-2"
      assert user.drive_connected_at == drive_connected_at
    end

    test "a feature unticked on the consent screen is dropped, since the new token lacks it" do
      user = drive_user()

      assert {:ok, user} =
               GoogleAuth.store_credentials(
                 user,
                 creds(%{refresh_token: "refresh-2", scopes: ["email", @calendar]}),
                 :calendar
               )

      refute GoogleAuth.connected?(user, :drive)
      assert GoogleAuth.connected?(user, :calendar)
      assert user.google_scopes == [@calendar]
      assert user.drive_connected_at == nil
    end

    test "a feature disconnected earlier does not come back with another feature's consent" do
      user = drive_user()
      google(self())
      {:ok, user} = Accounts.update_user(user, %{google_scopes: [@drive, @calendar]})
      {:ok, user} = GoogleAuth.disconnect(user, :drive)
      refute GoogleAuth.connected?(user, :drive)

      # Google hands the whole grant back, Drive included (include_granted_scopes)
      assert {:ok, user} =
               GoogleAuth.store_credentials(
                 user,
                 creds(%{scopes: ["email", @drive, @calendar]}),
                 :calendar
               )

      refute GoogleAuth.connected?(user, :drive)
      assert user.google_scopes == [@calendar]
    end
  end

  describe "disconnect/2" do
    test "one feature of two: forgotten here, the grant kept for the other" do
      user = drive_user()
      google(self())
      {:ok, user} = Accounts.update_user(user, %{google_scopes: [@drive, @calendar]})

      assert {:ok, user} = GoogleAuth.disconnect(user, :drive)
      refute_received {:google, "POST", "oauth2.googleapis.com", "/revoke", _}
      refute GoogleAuth.connected?(user, :drive)
      refute GoogleDrive.connected?(user)
      assert GoogleAuth.connected?(user, :calendar)
      assert user.google_refresh_token == "refresh-1"
      assert user.drive_connected_at == nil
    end

    test "the last feature revokes the grant with Google and forgets it" do
      user = drive_user()
      google(self())

      assert {:ok, user} = GoogleAuth.disconnect(user, :drive)
      assert_receive {:google, "POST", "oauth2.googleapis.com", "/revoke", form}
      assert form =~ "token=refresh-1"
      refute GoogleAuth.connected?(user, :drive)
      assert user.google_refresh_token == nil
      assert user.google_access_token == nil
      assert user.google_scopes == []
    end
  end

  describe "access_token/1" do
    test "refreshes an expired token once for every feature" do
      user = drive_user()
      google(self())

      {:ok, user} =
        Accounts.update_user(user, %{
          google_token_expires_at:
            DateTime.add(DateTime.utc_now(), -10) |> DateTime.truncate(:second)
        })

      assert {:ok, user, "access-2"} = GoogleAuth.access_token(user)
      assert_receive {:google, "POST", "oauth2.googleapis.com", "/token", form}
      assert form =~ "refresh_token=refresh-1"
      assert {:ok, _user, "access-2"} = GoogleAuth.access_token(user)
      refute_received {:google, "POST", "oauth2.googleapis.com", "/token", _}
    end

    test "a grant revoked in Google forgets every feature" do
      user = drive_user()
      {:ok, user} = Accounts.update_user(user, %{google_scopes: [@drive, @calendar]})

      {:ok, user} =
        Accounts.update_user(user, %{
          google_token_expires_at:
            DateTime.add(DateTime.utc_now(), -10) |> DateTime.truncate(:second)
        })

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, :reconnect} = GoogleAuth.access_token(user)
      user = Accounts.get_user!(user.id)
      refute GoogleAuth.connected?(user, :drive)
      refute GoogleAuth.connected?(user, :calendar)
      assert user.google_scopes == []
    end
  end

  test "the tokens never leave the app through the change stream; the scopes do" do
    for field <- ~w(google_refresh_token google_access_token) do
      assert Serializer.redacted_field?("users", field)
    end

    refute Serializer.redacted_field?("users", "google_scopes")
    refute Serializer.redacted_field?("users", "drive_connected_at")
  end
end
