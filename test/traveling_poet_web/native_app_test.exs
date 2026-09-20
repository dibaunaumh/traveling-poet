defmodule TravelingPoetWeb.NativeAppTest do
  @moduledoc """
  What the site does differently inside the iOS app, which it recognises by a
  `TravelingPoetiOS/<version>` suffix on the User-Agent.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Books
  alias TravelingPoet.Books.PdfRenderer
  alias TravelingPoetWeb.Plugs.NativeApp

  @app_ua "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 TravelingPoetiOS/1.0.0"
  @safari_ua "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Mobile/15E148 Safari/604.1"

  defp in_app(conn), do: put_req_header(conn, "user-agent", @app_ua)
  defp in_safari(conn), do: put_req_header(conn, "user-agent", @safari_ua)
  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "the User-Agent suffix is the whole signal" do
    assert NativeApp.native?(@app_ua)
    assert NativeApp.native?("TravelingPoetiOS/12")
    refute NativeApp.native?(@safari_ua)
    refute NativeApp.native?("NotTravelingPoetiOS/1.0")
    refute NativeApp.native?("TravelingPoetiOS")
    refute NativeApp.native?(nil)
  end

  test "pages are marked for the app, and only for the app", %{conn: conn} do
    assert conn |> in_app() |> get(~p"/privacy") |> html_response(200) =~ ~s(data-native="ios")
    refute conn |> in_safari() |> get(~p"/privacy") |> html_response(200) =~ "data-native"
    refute conn |> get(~p"/privacy") |> html_response(200) =~ "data-native"
  end

  describe "credits" do
    setup do
      user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
      poet_fixture(user)
      %{user: user}
    end

    test "Settings offers no card checkout inside the app", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn |> signed_in(user) |> in_safari(), ~p"/settings")
      assert has_element?(view, ~s(#credit-packs form[action="/credits/checkout"]))

      {:ok, view, html} = live(conn |> signed_in(user) |> in_app(), ~p"/settings")
      refute has_element?(view, "#credit-packs")
      refute html =~ "/credits/checkout"
      # the balance and the ledger are still there
      assert has_element?(view, "#credits")
    end

    test "and the checkout cannot be reached by hand from there", %{conn: conn, user: user} do
      conn =
        conn |> signed_in(user) |> in_app() |> post(~p"/credits/checkout", %{"pack" => "p50"})

      assert redirected_to(conn) == "/settings#credits"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "App Store"
    end
  end

  describe "the book's PDF" do
    setup do
      Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
      on_exit(fn -> Application.delete_env(:traveling_poet, :sprites_client) end)

      user = agent_user_fixture(%{onboarding_completed: true, name: "Udi Bauman"})
      {:ok, user} = TravelingPoet.Accounts.update_user(user, %{sprite_name: "sandbox-#{user.id}"})
      poet = poet_fixture(user, %{name: "Wren", is_public: false})
      published_entry_fixture(poet, %{title: "Trams"})

      {:ok, pdf} = Books.request_pdf(user, poet)
      PdfRenderer.run(pdf.id)
      %{user: user, pdf: pdf}
    end

    test "a browser downloads it; the app, which cannot download, is shown it in place",
         %{conn: conn, user: user, pdf: pdf} do
      browser = conn |> signed_in(user) |> in_safari() |> get(~p"/journal/book/pdf/#{pdf.id}")
      assert redirected_to(browser) =~ "as=attachment"

      app = conn |> signed_in(user) |> in_app() |> get(~p"/journal/book/pdf/#{pdf.id}")
      assert redirected_to(app) =~ "as=inline"
    end

    test "as JSON the link comes back as data, for the in-app browser sheet",
         %{conn: conn, user: user, pdf: pdf} do
      conn =
        conn |> signed_in(user) |> in_app() |> get(~p"/journal/book/pdf/#{pdf.id}?format=json")

      assert %{"url" => "https://bucket.example/get/" <> rest} = json_response(conn, 200)
      assert rest =~ "as=inline"

      stranger = user_fixture(%{onboarding_completed: true})

      assert build_conn()
             |> signed_in(stranger)
             |> get(~p"/journal/book/pdf/#{pdf.id}?format=json")
             |> response(404)
    end

    test "the book drops its Print button, which a web view cannot honour",
         %{conn: conn, user: user} do
      assert conn |> signed_in(user) |> get(~p"/journal/book") |> html_response(200) =~
               ~s(id="book-print")

      html = conn |> signed_in(user) |> in_app() |> get(~p"/journal/book") |> html_response(200)
      refute html =~ ~s(id="book-print")
      # the way back is still there: no browser chrome in the app
      assert html =~ "Back to the journal"
    end
  end

  describe "the session" do
    test "outlives the process that holds the cookie", %{conn: conn} do
      user = user_fixture(%{onboarding_completed: true})
      conn = conn |> signed_in(user) |> get(~p"/privacy")

      assert %{max_age: max_age} = conn.resp_cookies["_traveling_poet_key"]
      assert max_age == 180 * 24 * 60 * 60
    end

    test "is re-issued as it ages, so the clock runs from the last visit", %{conn: conn} do
      user = user_fixture(%{onboarding_completed: true})
      now = System.system_time(:second)

      # first visit after sign-in: stamped
      first = conn |> signed_in(user) |> get(~p"/privacy")
      assert_in_delta get_session(first, :refreshed_at), now, 5

      # a fresh stamp is left alone (no new cookie on every request)
      recent = now - 3600
      session = %{user_id: user.id, refreshed_at: recent}
      fresh = build_conn() |> Plug.Test.init_test_session(session) |> get(~p"/privacy")
      assert get_session(fresh, :refreshed_at) == recent

      # a week-old one is renewed
      old = now - 8 * 24 * 60 * 60
      session = %{user_id: user.id, refreshed_at: old}
      stale = build_conn() |> Plug.Test.init_test_session(session) |> get(~p"/privacy")
      assert_in_delta get_session(stale, :refreshed_at), now, 5
    end

    test "a visitor who is not signed in gets no stamp", %{conn: conn} do
      conn = get(conn, ~p"/privacy")
      assert is_nil(get_session(conn, :refreshed_at))
    end
  end

  test "there is a support page to point an App Store listing at", %{conn: conn} do
    html = conn |> get(~p"/support") |> html_response(200)
    assert html =~ "Support"
    assert html =~ "mailto:"
  end
end
