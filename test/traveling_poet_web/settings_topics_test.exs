defmodule TravelingPoetWeb.SettingsTopicsTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Topics

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp mount(conn) do
    user = user_fixture(%{onboarding_completed: true})
    poet = poet_fixture(user)
    {:ok, view, html} = live(sign_in(conn, user), ~p"/settings")
    {user, poet, view, html}
  end

  test "adds a topic, edits its cadence and kind, pauses and removes it", %{conn: conn} do
    {_user, poet, view, html} = mount(conn)
    assert html =~ "None yet."

    html =
      view
      |> form("#add-topic-form", %{"label" => "Kit airplanes", "kind" => "personal"})
      |> render_submit()

    assert html =~ "Kit airplanes"
    refute html =~ "None yet."
    [topic] = Topics.list(poet.id)
    assert topic.status == "active"
    assert topic.kind == "personal"

    view
    |> form("#topic-form-#{topic.id}", %{
      "topic_id" => topic.id,
      "label" => "Kit airplanes",
      "kind" => "professional",
      "every_days" => "14"
    })
    |> render_change()

    updated = Topics.get(poet.id, topic.id)
    assert updated.every_days == 14
    assert updated.kind == "professional"

    # a blank label mid-edit keeps the current one
    view
    |> form("#topic-form-#{topic.id}", %{
      "topic_id" => topic.id,
      "label" => "  ",
      "every_days" => "14"
    })
    |> render_change()

    assert Topics.get(poet.id, topic.id).label == "Kit airplanes"

    html = render_click(view, "pause_topic", %{"id" => to_string(topic.id)})
    assert html =~ "paused"
    assert Topics.get(poet.id, topic.id).status == "paused"

    html = render_click(view, "resume_topic", %{"id" => to_string(topic.id)})
    refute html =~ ">paused<"
    assert Topics.get(poet.id, topic.id).status == "active"

    html = render_click(view, "remove_topic", %{"id" => to_string(topic.id)})
    assert html =~ "None yet."
    assert Topics.list(poet.id) == []
  end

  test "a topic the poet proposed can be kept or dropped", %{conn: conn} do
    {_user, poet, view, _html} = mount(conn)

    {:ok, proposed, false} =
      Topics.propose(poet.id, %{label: "Embodied minds", evidence: %{"quote" => "my whole thing"}})

    html = render(view)
    refute html =~ "Embodied minds"

    # the view reads topics at mount; a fresh mount sees the proposal
    {:ok, view, html} = live(sign_in(build_conn(), poet_owner(poet)), ~p"/settings")
    assert html =~ "Embodied minds"
    assert html =~ "proposed by your poet"
    assert html =~ "my whole thing"
    assert html =~ "Keep"

    html = render_click(view, "keep_topic", %{"id" => to_string(proposed.id)})
    refute html =~ "proposed by your poet"
    kept = Topics.get(poet.id, proposed.id)
    assert kept.status == "active"
    assert kept.source == "settings"

    {:ok, other, false} = Topics.propose(poet.id, %{label: "Ceramics"})
    {:ok, view, _html} = live(sign_in(build_conn(), poet_owner(poet)), ~p"/settings")
    html = render_click(view, "remove_topic", %{"id" => to_string(other.id)})
    refute html =~ "Ceramics"
    assert is_nil(Topics.get(poet.id, other.id))
  end

  test "a taste is added with its domain and shows it", %{conn: conn} do
    {_user, poet, view, _html} = mount(conn)

    html =
      view
      |> form("#add-taste-music", %{"label" => "post-rock"})
      |> render_submit()

    taste = Topics.get_by_label(poet.id, "post-rock")
    assert taste.domain == "music"
    assert taste.status == "active"
    assert html =~ ~s(id="tastes-music")
    assert html =~ "post-rock"
    # the subjects list above stays subjects only
    refute view |> element("#topics #topic-#{taste.id}") |> has_element?()
    assert view |> element("#tastes-music #topic-#{taste.id}") |> has_element?()
  end

  test "a duplicate topic is refused with a flash, not a crash", %{conn: conn} do
    {_user, _poet, view, _html} = mount(conn)

    view |> form("#add-topic-form", %{"label" => "Kit airplanes"}) |> render_submit()
    html = view |> form("#add-topic-form", %{"label" => "kit AIRPLANES"}) |> render_submit()
    assert html =~ "Could not save the topic"
  end

  test "each topic says when its next excursion is, and chat requests can be removed",
       %{conn: conn} do
    {_user, poet, _view, _html} = mount(conn)
    topic = topic_fixture(poet, %{label: "Kit airplanes"})
    queued = excursion_fixture(poet, topic, nil, %{requested_destination: "Oshkosh AirVenture"})

    {:ok, view, html} = live(sign_in(build_conn(), poet_owner(poet)), ~p"/settings")
    assert html =~ "no excursion yet, next on the first day"
    assert html =~ "Asked for in chat"
    assert html =~ "Oshkosh AirVenture"

    html = render_click(view, "remove_excursion", %{"id" => to_string(queued.id)})
    refute html =~ "Oshkosh AirVenture"
    assert Topics.list_queued(poet.id) == []

    two_days_ago = Date.add(Date.utc_today(), -2)
    entry = published_entry_fixture(poet, %{entry_date: two_days_ago})
    excursion_fixture(poet, topic, entry)

    {:ok, _view, html} = live(sign_in(build_conn(), poet_owner(poet)), ~p"/settings")
    assert html =~ "last excursion #{Calendar.strftime(two_days_ago, "%b %-d")}, next in 5 days"
  end

  defp poet_owner(poet), do: TravelingPoet.Accounts.get_user!(poet.user_id)
end
