defmodule TravelingPoetWeb.AiCReadTest do
  # The Alice-in-Context read tap on the two entry pages: the owner's journal and a
  # public journal. The dead render emits nothing; the live mount emits one read.
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias AliceInContext.Outbox
  alias TravelingPoet.Journal

  setup do
    Application.put_env(:alice_in_context, :endpoint, "http://aic.test")
    Application.put_env(:alice_in_context, :token, "tok")
    test_pid = self()

    Req.Test.stub(AliceInContext, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:aic_batch, Jason.decode!(body)})
      Req.Test.json(%Plug.Conn{conn | status: 202}, %{status: "accepted"})
    end)

    Req.Test.allow(AliceInContext, self(), Process.whereis(Outbox))

    on_exit(fn ->
      Application.delete_env(:alice_in_context, :endpoint)
      Application.delete_env(:alice_in_context, :token)
    end)

    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{is_public: true})

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-08-25], %{title: "The rooftop", place_name: "Lisbon"})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{kind: "description", body: "a day, coffee at Cafe Museum"}
      ])

    {:ok, entry} = Journal.publish_entry(entry)
    %{user: user, poet: poet, entry: entry}
  end

  defp reads do
    Outbox.flush()

    receive do
      {:aic_batch, %{"events" => events}} -> Enum.filter(events, &(&1["verb"] == "read"))
    after
      2_000 -> []
    end
  end

  test "the owner opening their journal page reads the entry", %{
    conn: conn,
    user: user,
    poet: poet,
    entry: entry
  } do
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    {:ok, _view, _html} = live(conn, ~p"/journal/2026-08-25")

    assert [read] = reads()

    assert read["actor"]["id"] == "user-#{user.id}" and
             read["recipient"]["id"] == "poet-#{poet.id}"

    assert read["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
    assert read["metadata"]["channel"] == "owner"
  end

  test "a signed-in reader of a public page reads it; an anonymous visit is not reported",
       %{conn: conn, poet: poet, entry: entry} do
    {:ok, _view, _html} = live(conn, ~p"/p/#{poet.slug}/2026-08-25")
    assert reads() == []

    reader = user_fixture()
    conn = Plug.Test.init_test_session(conn, %{user_id: reader.id})
    {:ok, _view, _html} = live(conn, ~p"/p/#{poet.slug}/2026-08-25")

    assert [read] = reads()

    assert read["actor"]["id"] == "user-#{reader.id}" and
             read["recipient"]["id"] == "poet-#{poet.id}"

    assert read["actor"]["name"] == reader.name

    assert read["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
    assert read["metadata"]["channel"] == "public"
  end
end
