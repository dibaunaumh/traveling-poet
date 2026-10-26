defmodule TravelingPoetWeb.NpsPromptTest do
  @moduledoc """
  The recommend question under a fresh page (card-137): from day 7, the
  score kept on the tap, the words after it, then resting; Not now rests it.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Journal, Repo}
  alias TravelingPoet.Feedback.NpsResponse

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp publish_day(poet, date) do
    {:ok, entry} =
      Journal.upsert_entry(poet.id, date, %{title: "Day #{date}", place_name: "Lisbon"})

    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: "a day"}])
    {:ok, entry} = Journal.publish_entry(entry)
    entry
  end

  # Pages from `days - 1` days ago through today: the latest is day `days`
  defp reader_with_days(days) do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{name: "Wren", is_public: true, status: "active"})
    today = Date.utc_today()
    entries = for n <- (days - 1)..0//-1, do: publish_day(poet, Date.add(today, -n))
    {user, poet, List.last(entries)}
  end

  # The poet's own question goes first; out of the way, the journal may ask
  defp journal_without_poet_question(conn) do
    {:ok, view, _html} = live(conn, ~p"/journal")

    if has_element?(view, "button[phx-click='prompt_dismiss']") do
      refute has_element?(view, "#nps-prompt")
      view |> element("button[phx-click='prompt_dismiss']") |> render_click()
    end

    view
  end

  test "not before the seventh page", %{conn: conn} do
    {user, _poet, _} = reader_with_days(6)
    view = journal_without_poet_question(sign_in(conn, user))
    refute has_element?(view, "#nps-prompt")
  end

  test "on day 7: a score, then the words, then thanks; not asked again", %{conn: conn} do
    {user, _poet, latest} = reader_with_days(7)
    owner = sign_in(conn, user)
    view = journal_without_poet_question(owner)

    assert has_element?(view, "#nps-prompt")
    # The invite waits for another page
    refute has_element?(view, "#invite-prompt")

    view |> element("#nps-prompt button[phx-value-score='6']") |> render_click()

    assert [%NpsResponse{score: 6, comment: nil, journal_entry_id: entry_id}] =
             Repo.all(NpsResponse)

    assert entry_id == latest.id
    assert has_element?(view, "#nps-comment-form", "What would make it better?")

    view |> form("#nps-comment-form", comment: "More maps") |> render_submit()
    assert has_element?(view, "#nps-thanks")
    assert [%NpsResponse{comment: "More maps"}] = Repo.all(NpsResponse)

    view = journal_without_poet_question(owner)
    refute has_element?(view, "#nps-prompt")
    assert has_element?(view, "#invite-prompt")
  end

  test "a high score asks what they love, and Skip finishes it", %{conn: conn} do
    {user, _poet, _} = reader_with_days(8)
    view = journal_without_poet_question(sign_in(conn, user))

    view |> element("#nps-prompt button[phx-value-score='10']") |> render_click()
    assert has_element?(view, "#nps-comment-form", "What do you love most about it?")

    view |> element("#nps-prompt button", "Skip") |> render_click()
    assert has_element?(view, "#nps-thanks")
    assert [%NpsResponse{score: 10, comment: nil}] = Repo.all(NpsResponse)
  end

  test "Not now rests it", %{conn: conn} do
    {user, _poet, _} = reader_with_days(7)
    owner = sign_in(conn, user)
    view = journal_without_poet_question(owner)

    view |> element("#nps-prompt button", "Not now") |> render_click()
    refute has_element?(view, "#nps-prompt")
    assert Accounts.get_user!(user.id).nps_prompt_dismissed_at
    assert Repo.all(NpsResponse) == []

    view = journal_without_poet_question(owner)
    refute has_element?(view, "#nps-prompt")
  end

  test "the poet's question, once waved off, stays off and lets it ask", %{conn: conn} do
    {user, _poet, _} = reader_with_days(7)
    owner = sign_in(conn, user)

    # A new reader with few preferences is asked on every page (cold start)
    {:ok, view, _html} = live(owner, ~p"/journal")
    assert has_element?(view, "button[phx-click='prompt_dismiss']")
    refute has_element?(view, "#nps-prompt")
    view |> element("button[phx-click='prompt_dismiss']") |> render_click()

    {:ok, view, _html} = live(owner, ~p"/journal")
    refute has_element?(view, "button[phx-click='prompt_dismiss']")
    assert has_element?(view, "#nps-prompt")
  end

  test "only under the latest page", %{conn: conn} do
    {user, _poet, _} = reader_with_days(8)
    yesterday = Date.utc_today() |> Date.add(-1) |> Date.to_iso8601()
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/journal/#{yesterday}")
    refute has_element?(view, "#nps-prompt")
  end
end
