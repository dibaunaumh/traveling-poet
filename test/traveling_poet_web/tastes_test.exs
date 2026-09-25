defmodule TravelingPoetWeb.TastesTest do
  @moduledoc """
  Tastes: topics with a domain. The poet asks about one domain at a time,
  the answer becomes a taste, and a taste's excursion day is a discovery
  that must never bring back the same find twice.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Asks, Chat, Poets, Topics}
  alias TravelingPoet.Preferences.Prompts
  alias TravelingPoet.Topics.Find

  setup %{conn: conn} do
    user = agent_user_fixture()
    days_ago = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
    poet = poet_fixture(user, %{arrived_at: days_ago})

    for i <- 1..3,
        do: published_entry_fixture(poet, %{entry_date: Date.add(Date.utc_today(), -i - 1)})

    authed =
      conn
      |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
      |> put_req_header("content-type", "application/json")

    %{conn: authed, user: user, poet: poet}
  end

  test "with a topic, the poet asks about music; the answer becomes a music taste",
       %{conn: conn, user: user, poet: poet} do
    topic_fixture(poet, %{label: "Embodied minds"})

    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["ask_reader"] == %{"about" => "music", "reason" => "domain"}

    %{"ask" => %{"id" => id, "about" => "music"}} =
      conn
      |> post(~p"/api/agent/asks", %{"question" => "What have you been listening to lately?"})
      |> json_response(200)

    framed = Asks.frame_reply(user.id, "Mogwai, Sigur Ros, anything slow")
    assert framed =~ "taste in music"

    Chat.create_message(%{user_id: user.id, role: "user", content: "Mogwai, Sigur Ros"})

    # the poet forgot the domain: the ask supplies it
    body =
      conn
      |> post(~p"/api/agent/topics", %{"label" => "post-rock like Mogwai", "ask_id" => id})
      |> json_response(200)

    assert body["topic"]["domain"] == "music"
    assert body["topic"]["status"] == "active"

    # music is known now: next week is books
    assert Asks.facts(poet.id).domains_known == ["music"]
  end

  test "a taste heard in chat is proposed with its domain; a made-up domain is refused",
       %{conn: conn, poet: poet} do
    body =
      conn
      |> post(~p"/api/agent/topics", %{"label" => "Japanese city pop", "domain" => "music"})
      |> json_response(200)

    assert body["topic"]["status"] == "proposed"
    assert Topics.get_by_label(poet.id, "Japanese city pop").domain == "music"

    assert conn
           |> post(~p"/api/agent/topics", %{"label" => "tapas", "domain" => "food"})
           |> json_response(422)
  end

  test "a taste day is a discovery that never repeats a find", %{conn: conn, poet: poet} do
    taste = topic_fixture(poet, %{label: "post-rock", domain: "music"})

    earlier = published_entry_fixture(poet, %{entry_date: Date.add(Date.utc_today(), -10)})
    excursion_fixture(poet, taste, earlier)

    {:ok, _} =
      Topics.replace_finds(earlier, [
        %{"name" => "Young Team", "url" => "https://example.com/young-team", "kind" => "music"}
      ])

    travel = Poets.travel_plan(Poets.get_poet!(poet.id))
    assert travel.day == "excursion"
    assert travel.reason =~ "taste in music"
    assert travel.excursion.domain == "music"
    assert travel.excursion.past_finds == ["Young Team"]

    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    [topic] = body["topics"]
    assert topic["domain"] == "music"
    assert topic["past_finds"] == ["Young Team"]
  end

  test "taste finds have their own kinds and their own Guide group" do
    assert Find.normalize_kind("music") == "music"
    assert Find.group_for("book") == "works"
    assert Find.group_for("screen") == "works"
    assert Find.group_for("outing") == "happenings"
    assert "works" in Find.filter_groups()
  end

  test "the question under a taste day asks whether the finds landed", %{poet: poet} do
    taste = topic_fixture(poet, %{label: "post-rock", domain: "music"})
    subject = topic_fixture(poet, %{label: "Kit airplanes"})

    %{question: q, options: opts} =
      Prompts.excursion_check_in(nil, %{topic: taste, topic_id: taste.id})

    assert q == "Finds for your taste in music. Did they land?"
    assert Enum.any?(opts, &(&1["label"] == "Not quite my taste"))

    %{question: q} = Prompts.excursion_check_in(nil, %{topic: subject, topic_id: subject.id})
    assert q == "An excursion into Kit airplanes. Worth the day?"
  end
end
