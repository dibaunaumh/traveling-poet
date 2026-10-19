defmodule TravelingPoetWeb.LocaleTest do
  @moduledoc """
  One language per account sets the interface and the poet's writing
  (card-101, dec-008); a visitor gets their own.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Journal, Locale, Repo}
  alias TravelingPoet.Accounts.User

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  describe "Locale" do
    test "reads Accept-Language by quality, Hebrew under either code" do
      assert Locale.from_accept_language("he-IL,he;q=0.9,en-US;q=0.8") == "he"
      assert Locale.from_accept_language("iw-IL") == "he"
      assert Locale.from_accept_language("fr-FR,en;q=0.5,he;q=0.7") == "he"
      assert Locale.from_accept_language("en-US,he;q=0") == "en"
      assert Locale.from_accept_language("fr-FR,de;q=0.9") == nil
      assert Locale.from_accept_language(nil) == nil
    end

    test "direction" do
      assert Locale.dir("he") == "rtl"
      assert Locale.dir("en") == "ltr"
      assert Locale.dir(nil) == "ltr"
    end
  end

  describe "a visitor" do
    test "gets the language their browser asks for, on <html>", %{conn: conn} do
      html =
        conn
        |> put_req_header("accept-language", "he-IL,he;q=0.9")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ ~r/<html[^>]* lang="he" dir="rtl"/
    end

    test "falls back to English for a language the app does not speak", %{conn: conn} do
      html =
        conn
        |> put_req_header("accept-language", "fr-FR")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ ~r/<html[^>]* lang="en" dir="ltr"/
    end

    test "?lang= wins and is remembered in the session", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept-language", "en-US")
        |> get(~p"/?lang=he")

      assert html_response(conn, 200) =~ ~s(lang="he")
      assert get_session(conn, :locale) == "he"

      html =
        conn
        |> recycle()
        |> put_req_header("accept-language", "en-US")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ ~s(lang="he")
    end

    test "a LiveView mounts in the session's language", %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, %{locale: "he"})
      {:ok, view, html} = live(conn, ~p"/discover")

      assert html =~ ~s(dir="rtl")
      assert :sys.get_state(view.pid).socket.assigns.locale == "he"
    end
  end

  describe "a signed-in reader" do
    test "gets their own setting, whatever the browser says", %{conn: conn} do
      user = user_fixture(%{locale: "he", onboarding_completed: true})
      _poet = poet_fixture(user)

      html =
        conn
        |> sign_in(user)
        |> put_req_header("accept-language", "en-US")
        |> get(~p"/privacy")
        |> html_response(200)

      assert html =~ ~r/<html[^>]* lang="he" dir="rtl"/
    end

    test "switches language in Settings, with a full reload", %{conn: conn} do
      user = user_fixture(%{onboarding_completed: true})
      _poet = poet_fixture(user)

      {:ok, view, _html} = live(sign_in(conn, user), ~p"/settings")

      assert {:error, {:redirect, %{to: "/settings#account"}}} =
               view |> form("#locale-form", %{locale: "he"}) |> render_change()

      assert Repo.get!(User, user.id).locale == "he"
    end

    test "switches language on onboarding's first step", %{conn: conn} do
      user = user_fixture()

      {:ok, view, _html} = live(sign_in(conn, user), ~p"/onboarding")

      assert {:error, {:redirect, %{to: "/onboarding"}}} =
               view
               |> element(~s(#onboarding-locale button[phx-value-locale="he"]))
               |> render_click()

      assert Repo.get!(User, user.id).locale == "he"
    end

    test "an unsupported language is refused" do
      user = user_fixture()
      assert {:error, :unsupported} = Accounts.set_locale(user, "xx")
      assert {:error, _} = Accounts.update_user(user, %{locale: "xx"})
    end
  end

  describe "sign-up" do
    test "a new account takes the detected language; an existing one keeps its own" do
      {:ok, new} =
        Accounts.find_or_create_from_oauth(:google, %{
          "sub" => "g-locale-new",
          "email" => "locale-new@example.com",
          "name" => "New",
          "locale" => "he"
        })

      assert new.locale == "he"

      existing = user_fixture()

      {:ok, again} =
        Accounts.find_or_create_from_oauth(:google, %{
          "sub" => existing.google_id,
          "email" => existing.email,
          "locale" => "he"
        })

      assert again.locale == "en"
    end
  end

  describe "a saved page" do
    setup %{conn: conn} do
      user = agent_user_fixture(%{locale: "he"})
      poet = poet_fixture(user)

      authed =
        conn
        |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
        |> put_req_header("content-type", "application/json")

      %{conn: authed, user: user, poet: poet}
    end

    test "is stamped with its reader's language", %{conn: conn, poet: poet} do
      date = Date.utc_today()

      conn
      |> post(~p"/api/agent/journal_entries", %{
        "entry_date" => Date.to_iso8601(date),
        "title" => "יום בעיר"
      })
      |> json_response(200)

      assert Journal.get_entry(poet.id, date).language == "he"
    end
  end
end
