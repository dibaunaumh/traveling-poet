defmodule TravelingPoetWeb.AsksTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Ecto.Query
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Asks, Chat, Repo, Telegram, Topics, WebPush}
  alias TravelingPoet.Asks.Ask

  setup %{conn: conn} do
    user = agent_user_fixture()
    poet = poet_fixture(user)

    authed =
      conn
      |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
      |> put_req_header("content-type", "application/json")

    %{conn: authed, user: user, poet: poet}
  end

  defp publish(poet, n) do
    for i <- 1..n,
        do: published_entry_fixture(poet, %{entry_date: Date.add(Date.utc_today(), -i)})
  end

  defp age(%Ask{} = ask, days) do
    at =
      NaiveDateTime.utc_now() |> NaiveDateTime.add(-days, :day) |> NaiveDateTime.truncate(:second)

    Repo.update_all(from(a in Ask, where: a.id == ^ask.id), set: [inserted_at: at])
  end

  defp ask!(conn, question \\ "What would you have me go looking into, off the road?") do
    conn |> post(~p"/api/agent/asks", %{"question" => question}) |> json_response(200)
  end

  test "the context says when to ask; the app, not the poet, decides",
       %{conn: conn, poet: poet} do
    publish(poet, 2)
    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["ask_reader"] == nil
    assert body["open_ask"] == nil

    # asking anyway is refused and kept nowhere
    assert conn
           |> post(~p"/api/agent/asks", %{"question" => "What are you into?"})
           |> json_response(409)

    assert Repo.aggregate(Ask, :count) == 0

    publish_on(poet, 0)
    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["ask_reader"] == %{"about" => "topics", "reason" => "no_topics"}
  end

  defp publish_on(poet, days_ago),
    do: published_entry_fixture(poet, %{entry_date: Date.add(Date.utc_today(), -days_ago)})

  test "an ask lands in the chat, is announced, and holds the next one back",
       %{conn: conn, user: user, poet: poet} do
    publish(poet, 3)
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "asks")
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")

    %{"ask" => %{"id" => id}} = ask!(conn)

    assert_receive {:reader_asked, user_id, ^id}
    assert user_id == user.id
    assert_receive {:poet_asked, message}
    assert message.role == "agent"
    assert message.content =~ "off the road"
    assert [%{content: content}] = Chat.list_messages(user.id)
    assert content == message.content

    body = conn |> get(~p"/api/agent/context") |> json_response(200)
    assert body["ask_reader"] == nil
    assert body["open_ask"]["id"] == id

    # a second question the same day is refused
    assert conn
           |> post(~p"/api/agent/asks", %{"question" => "And another thing?"})
           |> json_response(409)
  end

  test "any reader message is a reply; silence past the window is not",
       %{conn: conn, user: user, poet: poet} do
    publish(poet, 3)
    %{"ask" => %{"id" => id}} = ask!(conn)

    # the app's own triggers are not the reader talking
    Chat.create_message(%{user_id: user.id, role: "user", content: "/travel", channel: "system"})
    assert Asks.get(id).status == "open"

    Chat.create_message(%{
      user_id: user.id,
      role: "user",
      content: "not really",
      channel: "telegram"
    })

    ask = Asks.get(id)
    assert ask.status == "replied"
    assert ask.replied_at

    # a new poet whose ask went unanswered for longer than the window
    other = agent_user_fixture()
    other_poet = poet_fixture(other)
    publish(other_poet, 3)
    {:ok, stale} = Asks.create(other_poet, "What should I look into for you?")
    age(stale, Asks.reply_window_days() + 1)
    assert Asks.open_ask(other_poet.id) == nil
    Chat.create_message(%{user_id: other.id, role: "user", content: "hi"})
    assert Asks.get(stale.id).status == "open"
  end

  test "a topic from the answer is active at once; without ask_id it is only proposed",
       %{conn: conn, user: user, poet: poet} do
    publish(poet, 3)
    %{"ask" => %{"id" => id}} = ask!(conn)
    Chat.create_message(%{user_id: user.id, role: "user", content: "letterpress printing!"})

    body =
      conn
      |> post(~p"/api/agent/topics", %{
        "label" => "letterpress printing",
        "quote" => "letterpress printing!",
        "ask_id" => id
      })
      |> json_response(200)

    assert body["active"] == true
    assert body["already_known"] == false
    topic = Topics.get_by_label(poet.id, "letterpress printing")
    assert topic.status == "active"
    assert topic.source == "ask"
    assert topic.evidence["quote"] == "letterpress printing!"
    assert Asks.get(id).status == "answered"

    # the same poet, no ask_id: the old rule
    body =
      conn
      |> post(~p"/api/agent/topics", %{"label" => "kit airplanes"})
      |> json_response(200)

    assert body["topic"]["status"] == "proposed"
  end

  test "an answer keeps what the reader decided before, and another poet's ask is ignored",
       %{conn: conn, poet: poet} do
    publish(poet, 3)
    {:ok, paused} = Topics.create(poet.id, %{label: "jazz"})
    {:ok, _} = Topics.pause(paused)
    {:ok, waiting, false} = Topics.propose(poet.id, %{label: "tea"})
    # a paused topic means active_topics == 0, so the poet may ask
    %{"ask" => %{"id" => id}} = ask!(conn)

    body =
      conn
      |> post(~p"/api/agent/topics", %{"label" => "Jazz", "ask_id" => id})
      |> json_response(200)

    assert body["topic"]["status"] == "paused"
    assert body["note"] =~ "paused"

    conn |> post(~p"/api/agent/topics", %{"label" => "tea", "ask_id" => id}) |> json_response(200)
    assert Topics.get(poet.id, waiting.id).status == "active"

    other = agent_user_fixture()
    other_poet = poet_fixture(other)
    publish(other_poet, 3)
    {:ok, foreign} = Asks.create(other_poet, "What should I look into for you?")

    body =
      conn
      |> post(~p"/api/agent/topics", %{"label" => "origami", "ask_id" => foreign.id})
      |> json_response(200)

    assert body["topic"]["status"] == "proposed"
    assert Asks.get(foreign.id).status == "open"
  end

  test "the notification opens the chat; Telegram carries the question itself", %{poet: poet} do
    ask = %Ask{id: 7, question: "What should I hunt down for you?"}

    assert %{url: "/journal?chat=1", tag: "ask-7", body: "What should I hunt down for you?"} =
             WebPush.question_payload(poet, ask)

    text = Telegram.Notifier.question_text(poet, ask)
    assert text =~ "What should I hunt down for you?"
    assert text =~ poet.name
  end
end
