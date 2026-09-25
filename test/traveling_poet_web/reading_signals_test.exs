defmodule TravelingPoetWeb.ReadingSignalsTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Journal, Reading}
  alias TravelingPoet.Journal.Paragraphs

  @para "Lisbon hits you first by smell: salt, diesel, baking bread, and something floral."

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp owner_with_entry do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-09-25], %{title: "Day", place_name: "Lisbon"})

    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: @para}])
    {:ok, entry} = Journal.publish_entry(entry)
    {user, entry}
  end

  test "the owner's journal measures reading and records what the hook reports", %{conn: conn} do
    {user, entry} = owner_with_entry()
    {:ok, view, html} = live(sign_in(conn, user), ~p"/journal")

    assert html =~ ~s(phx-hook="ReadingTime")
    assert html =~ ~s(data-target="entry-#{entry.id}")

    render_hook(view, "paragraph_reads", %{
      "entry_id" => to_string(entry.id),
      "reads" => %{Paragraphs.key(@para) => 6_000}
    })

    assert [%{ms: 6_000}] = Reading.list(user)
  end

  test "with the switch off there is no hook and nothing is recorded", %{conn: conn} do
    {user, entry} = owner_with_entry()
    {:ok, user} = Accounts.update_user(user, %{reading_signals: false})
    {:ok, view, html} = live(sign_in(conn, user), ~p"/journal")

    refute html =~ "ReadingTime"

    render_hook(view, "paragraph_reads", %{
      "entry_id" => to_string(entry.id),
      "reads" => %{Paragraphs.key(@para) => 6_000}
    })

    assert Reading.list(user) == []
  end

  test "turning it off in Settings forgets what was noted; on again resumes", %{conn: conn} do
    {user, entry} = owner_with_entry()
    Reading.record(user, entry, %{Paragraphs.key(@para) => 6_000})
    {:ok, view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ "Learn from how I read"

    view |> form("#reading-signals-form", %{"reading_signals" => "false"}) |> render_change()
    refute Accounts.get_user!(user.id).reading_signals
    assert Reading.list(user) == []

    view |> form("#reading-signals-form", %{"reading_signals" => "true"}) |> render_change()
    assert Accounts.get_user!(user.id).reading_signals
  end

  test "each rendered paragraph's text gives the key the server computed", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user)

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-09-25], %{title: "Day", place_name: "Lisbon"})

    spot = media_fixture(poet, %{journal_entry_id: entry.id, kind: "spot", alt_text: "a cup"})
    place_fixture(poet, entry, %{name: "Cafe Museum"})

    body = """
    Coffee at **Cafe Museum**, where the *waiters* wear   black & white, and the cups are thin.

    ![a cup](/media/#{spot.id})
    The second paragraph is long enough, with `code`, a [link](https://example.com) and more.
    """

    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: body}])
    {:ok, _} = Journal.publish_entry(entry)

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/journal")

    rendered =
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query(~s([data-section-kind="description"] .prose > p))
      |> Enum.map(&Paragraphs.key(LazyHTML.text(&1)))

    expected = body |> Paragraphs.of_markdown() |> Enum.map(& &1.key)
    assert length(expected) == 2
    assert rendered == expected
  end

  test "Settings draws the taste map and lists the subjects; one can be taken off", %{conn: conn} do
    {user, entry} = owner_with_entry()
    path = "history-and-heritage/history-museums/local-history"

    TravelingPoet.Repo.insert!(%TravelingPoet.Journal.ParagraphSubject{
      poet_id: entry.poet_id,
      journal_entry_id: entry.id,
      key: Paragraphs.key(@para),
      topic: path,
      classified_at: DateTime.utc_now(:second)
    })

    TravelingPoet.Repo.insert!(%TravelingPoet.Journal.Marker{
      journal_entry_id: entry.id,
      user_id: user.id,
      kind: "interesting",
      target: "text",
      section_kind: "description",
      quote: "baking bread"
    })

    {:ok, view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ "Subjects you linger on"
    assert html =~ ~s(class="taste-map-dot is-for")
    assert view |> element("#lingering-list") |> render() =~ "Local history"

    view |> element(~s(#lingering-list button[phx-value-path="#{path}"])) |> render_click()
    refute has_element?(view, "#lingering-list")
    assert view |> element("#lingering-removed") |> render() =~ "Local history"
  end
end
