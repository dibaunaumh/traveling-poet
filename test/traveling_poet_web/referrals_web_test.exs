defmodule TravelingPoetWeb.ReferralsWebTest do
  @moduledoc "Invites on the web (card-126): the link, the welcome, the claim at sign-in, Settings, the prompt."
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Credits, Journal, Referrals}
  alias TravelingPoetWeb.UserAuth

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp new_reader(attrs \\ %{}) do
    user = user_fixture(attrs)
    {:ok, _} = Credits.grant_signup(user)
    Accounts.get_user!(user.id)
  end

  test "an invite link parks the code and the home page names the friend", %{conn: conn} do
    referrer = new_reader(%{name: "Dana Levi"})
    code = Referrals.code_for(referrer)

    conn = get(conn, ~p"/i/#{String.downcase(code)}")
    assert redirected_to(conn) == "/"
    assert get_session(conn, :referral_code) == code

    html = conn |> recycle() |> get(~p"/") |> html_response(200)
    assert html =~ ~s(id="invite-welcome")
    assert html =~ "Dana invited you. Your poet starts with 10 extra credits."
  end

  test "a shared page's ?ref= parks the code for someone signed out, not for a reader", %{
    conn: conn
  } do
    owner = new_reader()
    poet = poet_fixture(owner, %{is_public: true})
    code = Referrals.code_for(owner)

    conn = get(conn, ~p"/p/#{poet.slug}?#{[ref: code]}")
    assert get_session(conn, :referral_code) == code

    reader = new_reader()
    conn = build_conn() |> sign_in(reader) |> get(~p"/p/#{poet.slug}?#{[ref: code]}")
    assert get_session(conn, :referral_code) == nil
  end

  test "signing in claims the parked code, and only once", %{conn: conn} do
    referrer = new_reader()
    friend = new_reader()
    code = Referrals.code_for(referrer)

    conn =
      conn
      |> Plug.Test.init_test_session(%{referral_code: code})
      |> UserAuth.log_in_user(friend)

    # The session is fresh: the code went with the old one
    assert get_session(conn, :referral_code) == nil
    assert get_session(conn, :user_id) == friend.id
    assert Accounts.get_user!(friend.id).referred_by_id == referrer.id
    assert Credits.balance(Accounts.get_user!(friend.id)) == Credits.to_milli(20)
  end

  test "Settings shows the invite link and lets a new reader type a code", %{conn: conn} do
    referrer = new_reader(%{name: "Dana Levi", onboarding_completed: true})
    poet_fixture(referrer)
    code = Referrals.code_for(referrer)
    friend = new_reader(%{onboarding_completed: true})
    poet_fixture(friend, %{name: "Wren"})

    {:ok, view, html} = live(sign_in(conn, friend), ~p"/settings")
    assert html =~ "Invite friends"
    friend_code = Accounts.get_user!(friend.id).referral_code
    assert view |> element("#invite-url") |> render() =~ "/i/#{friend_code}"
    assert has_element?(view, "#settings-invite[phx-hook='ShareMenu']")

    html =
      view |> form("#invite-claim-form", %{code: friend_code}) |> render_submit()

    assert html =~ "That is your own code"

    html = view |> form("#invite-claim-form", %{code: String.downcase(code)}) |> render_submit()
    assert html =~ "10 extra credits are yours"
    assert html =~ "You joined through Dana"
    refute has_element?(view, "#invite-claim-form")
    assert Credits.balance(Accounts.get_user!(friend.id)) == Credits.to_milli(20)

    # The referrer, once the friend's first page is out, sees it counted
    published_entry_fixture(poet_of(friend))
    {:ok, _view, html} = live(build_conn() |> sign_in(referrer), ~p"/settings")
    assert html =~ "One friend joined through you"
    assert html =~ "(10 credits earned so far)."
  end

  defp poet_of(user), do: TravelingPoet.Poets.get_poet_by_user(user.id)

  defp publish_day(poet, date) do
    {:ok, entry} =
      Journal.upsert_entry(poet.id, date, %{title: "Day #{date}", place_name: "Lisbon"})

    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "a day"}])
    {:ok, entry} = Journal.publish_entry(entry)
    entry
  end

  test "the invite waits under a fresh latest page from day three, and rests after Not now", %{
    conn: conn
  } do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{name: "Wren", is_public: true, status: "active"})
    today = Date.utc_today()

    publish_day(poet, Date.add(today, -2))
    publish_day(poet, Date.add(today, -1))
    owner = sign_in(conn, user)

    # Day two: too early
    {:ok, view, _html} = live(owner, ~p"/journal")
    refute has_element?(view, "#invite-prompt")

    latest = publish_day(poet, today)

    # Never beside the poet's own open question...
    {:ok, view, _html} = live(owner, ~p"/journal")
    assert has_element?(view, "button[phx-click='prompt_dismiss']")
    refute has_element?(view, "#invite-prompt")

    # ...but once it is answered, there it is
    view |> element("button[phx-click='prompt_answer']:first-of-type") |> render_click()
    assert has_element?(view, "#invite-prompt")
    _ = latest

    {:ok, view, _html} = live(owner, ~p"/journal")
    assert has_element?(view, "#invite-prompt")
    code = Accounts.get_user!(user.id).referral_code
    link = "http://localhost:4000/p/#{poet.slug}/#{Date.to_iso8601(today)}?ref=#{code}"
    assert has_element?(view, "#invite-prompt-share[data-url='#{link}']")

    # Only under the latest page
    {:ok, view, _html} = live(owner, ~p"/journal/#{Date.to_iso8601(Date.add(today, -1))}")
    refute has_element?(view, "#invite-prompt")

    {:ok, view, _html} = live(owner, ~p"/journal")
    view |> element("#invite-prompt button", "Not now") |> render_click()
    refute has_element?(view, "#invite-prompt")
    {:ok, view, _html} = live(owner, ~p"/journal")
    refute has_element?(view, "#invite-prompt")
  end
end
