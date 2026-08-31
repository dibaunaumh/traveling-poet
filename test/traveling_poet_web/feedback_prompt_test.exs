defmodule TravelingPoetWeb.FeedbackPromptTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Preferences, Repo}

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp published_poet(attrs \\ %{}) do
    user = agent_user_fixture(Map.merge(%{onboarding_completed: true}, attrs))
    poet = poet_fixture(user, %{name: "Wren"})

    {:ok, entry} =
      Journal.upsert_entry(poet.id, Date.utc_today(), %{
        title: "A day in Lisbon",
        place_name: "Lisbon, Portugal"
      })

    {:ok, entry} = Journal.publish_entry(entry)
    {user, poet, entry}
  end

  test "a new reader is asked one question under the entry", %{conn: conn} do
    {user, _poet, _entry} = published_poet()

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/journal")

    # cold start: the poet knows nothing yet, so it asks
    assert html =~ "What would you like more of?" or html =~ "Was this the right length?" or
             html =~ "How's the pace" or html =~ "What draws you in most?" or
             html =~ "More places like"
  end

  # Which question the rotation picks depends on the entry, so drive the event
  # with a real option id rather than guessing at the button text.
  defp first_option_id(entry) do
    prompt = Repo.get_by(Preferences.EntryPrompt, journal_entry_id: entry.id)
    prompt |> Preferences.EntryPrompt.items() |> hd() |> Map.fetch!("id")
  end

  test "answering records a preference and confirms it in place", %{conn: conn} do
    {user, poet, entry} = published_poet()
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/journal")

    html = render_click(view, "prompt_answer", %{"option" => first_option_id(entry)})

    assert html =~ "Got it — Wren will keep that in mind."
    assert [preference] = Preferences.list_active(poet.id)
    assert preference.source == "tap"
    # the tap is attributed to the entry it was about
    assert preference.evidence["question"] != nil
  end

  test "undo removes what the tap taught", %{conn: conn} do
    {user, poet, entry} = published_poet()
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/journal")

    render_click(view, "prompt_answer", %{"option" => first_option_id(entry)})
    assert length(Preferences.list_active(poet.id)) == 1

    html = view |> element("button", "undo") |> render_click()

    assert Preferences.list_active(poet.id) == []
    refute html =~ "Got it —"
  end

  test "'not now' takes the question away without teaching anything", %{conn: conn} do
    {user, poet, entry} = published_poet()
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/journal")

    html = view |> element("button", "not now") |> render_click()

    refute html =~ "not now"
    assert Preferences.list_active(poet.id) == []
    # dismissal is itself a signal — it's recorded, so cadence can back off
    assert Repo.get_by(Preferences.EntryPrompt, journal_entry_id: entry.id).dismissed_at
  end

  test "opening an entry is recorded, so silence can be told from absence", %{conn: conn} do
    {user, _poet, entry} = published_poet()

    assert is_nil(Repo.reload(entry).owner_viewed_at)

    {:ok, _view, _html} = live(sign_in(conn, user), ~p"/journal")

    reloaded = Repo.reload(entry)
    assert reloaded.owner_viewed_at
    assert reloaded.owner_view_count == 1
  end

  test "a reader who is not the owner neither sees the prompt nor marks it read", %{conn: conn} do
    {_user, poet, entry} = published_poet()
    {:ok, _} = TravelingPoet.Poets.update_poet(poet, %{is_public: true})

    stranger = user_fixture()
    {:ok, _view, html} = live(sign_in(conn, stranger), ~p"/p/#{poet.slug}")

    refute html =~ "not now"
    assert is_nil(Repo.reload(entry).owner_viewed_at)
  end
end
