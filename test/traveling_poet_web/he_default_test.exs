defmodule TravelingPoetWeb.HeDefaultTest do
  @moduledoc """
  The default domain in Hebrew (card-101): the home page, the app's header,
  the support and legal pages, and the sign-in messages. A visitor who is
  not signed in can switch language from the home page footer.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Locale
  alias TravelingPoetWeb.NativeAuth

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "the home page speaks Hebrew to a visitor who asked for it", %{conn: conn} do
    html = conn |> get(~p"/?lang=he") |> html_response(200)

    assert html =~ "שלחו מישהו לפניכם."
    assert html =~ "שלחו את המשורר לדרך"
    assert html =~ "למה זו לא עוד אפליקציית טיולים."
    refute html =~ "Send someone ahead of you."
    refute html =~ "Send out your poet"
    # the wordmark is never translated
    assert html =~ "Traveling <em>Poet</em>"
  end

  test "an English visitor sees the home page as before", %{conn: conn} do
    html = conn |> put_req_header("accept-language", "en-US") |> get(~p"/") |> html_response(200)

    assert html =~ "Send someone ahead of you."
    assert html =~ "Why this isn’t another travel app."
    refute html =~ "שלחו מישהו לפניכם."
  end

  describe "the language link in the home page footer" do
    test "offers Hebrew to an English visitor", %{conn: conn} do
      html =
        conn |> put_req_header("accept-language", "en-US") |> get(~p"/") |> html_response(200)

      assert [link] = Regex.run(~r/<a[^>]*id="language-switch"[^>]*>\s*[^<]*<\/a>/u, html)
      assert link =~ ~s(href="?lang=he")
      assert link =~ ~s(lang="he")
      assert link =~ "עברית"
      refute link =~ "English"
    end

    test "offers English back to a Hebrew visitor, and the choice sticks", %{conn: conn} do
      conn = get(conn, ~p"/?lang=he")
      html = html_response(conn, 200)

      assert [link] = Regex.run(~r/<a[^>]*id="language-switch"[^>]*>\s*[^<]*<\/a>/u, html)
      assert link =~ ~s(href="?lang=en")
      assert link =~ ~s(lang="en")
      assert link =~ "English"

      # the next page, with no ?lang=, is still Hebrew
      html = conn |> recycle() |> get(~p"/") |> html_response(200)
      assert html =~ "שלחו מישהו לפניכם."

      # and following the link back gives English
      html = conn |> recycle() |> get(~p"/?lang=en") |> html_response(200)
      assert html =~ "Send someone ahead of you."
      assert html =~ ~s(href="?lang=he")
    end

    test "is not shown to a signed-in reader, who picks a language in Settings", %{conn: conn} do
      html = conn |> sign_in(user_fixture(%{locale: "he"})) |> get(~p"/") |> html_response(200)

      refute html =~ ~s(id="language-switch")
    end
  end

  test "a Hebrew reader gets the header and support page in Hebrew", %{conn: conn} do
    user = user_fixture(%{locale: "he"})
    html = conn |> sign_in(user) |> get(~p"/support") |> html_response(200)

    assert html =~ "יומן"
    assert html =~ "התנתקות"
    assert html =~ "העמודים הפסיקו להגיע"
    assert html =~ ~s(href="mailto:support@poet.travel")
    refute html =~ "Sign out"
    refute html =~ "My poet stopped writing"
  end

  describe "the legal pages" do
    test "keep the English body for a Hebrew reader and say it is the binding one", %{
      conn: conn
    } do
      html =
        conn |> sign_in(user_fixture(%{locale: "he"})) |> get(~p"/privacy") |> html_response(200)

      assert html =~ "המסמך מוצג באנגלית, וזו הגרסה המחייבת."
      assert html =~ "מדיניות פרטיות"
      assert html =~ "30 בספטמבר 2026"
      # the body itself stays English, left to right
      assert html =~ ~r/<article[^>]* class="legal" lang="en" dir="ltr"/
      assert html =~ "What the service stores"
    end

    test "say nothing extra to an English reader", %{conn: conn} do
      html = conn |> sign_in(user_fixture()) |> get(~p"/terms") |> html_response(200)

      refute html =~ ~s(id="legal-language-note")
      assert html =~ "Terms of Service"
      assert html =~ "Last updated 20 September 2026"
    end
  end

  test "the iOS app's connect outcomes come back in the reader's language" do
    assert {:info, "Connected to Google Drive."} = NativeAuth.connect_notice("drive:ok")

    Locale.with_locale("he", fn ->
      assert {:info, "החיבור ל-Google Drive הושלם."} = NativeAuth.connect_notice("drive:ok")
      assert {:error, text} = NativeAuth.connect_notice("calendar:failed")
      refute text =~ "Google did not grant"
    end)
  end

  test "error pages are in the reader's language" do
    Locale.with_locale("he", fn ->
      assert TravelingPoetWeb.ErrorHTML.render("404.html", %{}) == "הדף לא נמצא"
    end)

    assert TravelingPoetWeb.ErrorHTML.render("404.html", %{}) == "Not Found"
  end
end
