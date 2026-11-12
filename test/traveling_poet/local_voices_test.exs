defmodule TravelingPoet.LocalVoicesTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Journal, LocalVoices, Repo, WebPush}
  alias TravelingPoet.Accounts.Purge
  alias TravelingPoet.LocalVoices.Question

  @lisbon %{home_place_name: "Lisbon, Portugal", home_lat: 38.71, home_lng: -9.14}

  setup do
    # the visiting poet, in Lisbon (the fixture's place), and its reader
    visitor = agent_user_fixture()
    poet = poet_fixture(visitor, %{name: "Wren", status: "active"})
    %{visitor: visitor, poet: poet}
  end

  defp local_fixture(attrs \\ %{}) do
    user_fixture(
      Map.merge(@lisbon, %{name: "Dana Levi", local_voice: true, local_voice_credit: "name"})
      |> Map.merge(attrs)
    )
  end

  defp answered(poet, local, text \\ "Go to Feira da Ladra on a Tuesday morning.") do
    q = LocalVoices.maybe_ask(poet, DateTime.utc_now())
    assert q.user_id == local.id
    {:ok, q} = LocalVoices.answer(q, text)
    q
  end

  describe "who is asked" do
    test "a willing local near the poet, once per stay, with a notice", %{poet: poet} do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "local_voices")
      local = local_fixture()

      q = LocalVoices.maybe_ask(poet, DateTime.utc_now())
      assert %Question{user_id: user_id, place_name: "Lisbon, Portugal"} = q
      assert user_id == local.id
      assert_received {:local_question, ^user_id, _}

      # the same stay asks no one again
      assert LocalVoices.maybe_ask(poet, DateTime.utc_now()) == nil
    end

    test "never one who did not say yes, lives far, or reads this poet",
         %{poet: poet, visitor: visitor} do
      user_fixture(Map.put(@lisbon, :local_voice, false))

      user_fixture(%{
        home_place_name: "Porto",
        home_lat: 41.15,
        home_lng: -8.61,
        local_voice: true
      })

      Accounts.update_user(visitor, Map.put(@lisbon, :local_voice, true))

      assert LocalVoices.maybe_ask(poet, DateTime.utc_now()) == nil
    end

    test "a private poet asks no one", %{poet: poet} do
      local_fixture()
      {:ok, poet} = TravelingPoet.Poets.update_poet(poet, %{is_public: false})
      assert LocalVoices.maybe_ask(poet, DateTime.utc_now()) == nil
    end

    test "a local is asked at most once a week, by any poet", %{poet: poet} do
      local = local_fixture()
      assert LocalVoices.maybe_ask(poet, DateTime.utc_now())

      other = poet_fixture(user_fixture(), %{status: "active"})
      assert LocalVoices.pick_local(other) == nil

      assert LocalVoices.pick_local(other, DateTime.add(DateTime.utc_now(), 8, :day)).id ==
               local.id
    end
  end

  describe "answering" do
    test "an answer is kept; a question closes after a few days", %{poet: poet} do
      local = local_fixture()
      q = LocalVoices.maybe_ask(poet, DateTime.utc_now())

      assert LocalVoices.open?(q)
      refute LocalVoices.open?(q, DateTime.add(DateTime.utc_now(), LocalVoices.open_days(), :day))

      assert {:error, %Ecto.Changeset{}} = LocalVoices.answer(q, "  ")

      assert {:ok, %{status: "answered", answer: "The tiles museum."}} =
               LocalVoices.answer(q, " The tiles museum. ")

      assert LocalVoices.open_for(local.id) == []
    end

    test "the notice names the poet and the place, in every channel", %{poet: poet} do
      local_fixture()
      q = poet |> LocalVoices.maybe_ask(DateTime.utc_now()) |> Repo.preload(:poet)

      assert %{title: "Wren is in Lisbon", url: "/locals/" <> _} =
               WebPush.local_question_payload(q)

      assert TravelingPoet.Telegram.Notifier.local_question_text(q, "https://poet.travel") =~
               "https://poet.travel/locals/#{q.id}"

      user = Accounts.get_user!(q.user_id)
      message = TravelingPoet.Email.Notifier.local_question_message(user, q)
      assert message.subject == "Wren is in Lisbon"
      assert message.text =~ "/locals/#{q.id}"
    end
  end

  describe "on the page" do
    setup %{conn: conn, visitor: visitor} do
      authed =
        conn
        |> put_req_header("authorization", "Bearer #{visitor.agent_api_token}")
        |> put_req_header("content-type", "application/json")

      %{conn: authed}
    end

    defp put_sections(conn, sections) do
      conn
      |> put(~p"/api/agent/journal_entries/#{Date.to_iso8601(Date.utc_today())}/sections", %{
        sections: sections
      })
      |> json_response(200)
    end

    test "the poet is handed the answer, and the app credits the tip it puts",
         %{conn: conn, poet: poet} do
      local = local_fixture()
      q = answered(poet, local)

      context = conn |> get(~p"/api/agent/context") |> json_response(200)

      assert [%{"local_question_id" => id, "place" => "Lisbon, Portugal", "tips" => tips}] =
               context["local_voices"]

      assert id == q.id
      assert tips =~ "Feira da Ladra"

      entry = entry_fixture(poet)

      body =
        put_sections(conn, [
          %{kind: "description", body: "Words."},
          %{
            kind: "local_tip",
            body: "Feira da Ladra, on a Tuesday morning.",
            # whatever the poet writes about who it is from is replaced
            metadata: %{local_question_id: q.id, credit: %{style: "name", name: "Someone"}}
          },
          %{kind: "local_tip", body: "Made up.", metadata: %{local_question_id: 99_999}}
        ])

      assert body["section_count"] == 2
      assert body["refused_local_tips"] == [99_999]

      [_, tip] = Journal.preload_entry(entry).sections
      assert tip.metadata["credit"] == %{"style" => "name", "name" => "Dana", "place" => "Lisbon"}
      assert LocalVoices.credit_text(tip.metadata["credit"]) == "From Dana, who lives in Lisbon"
      assert Repo.get(Question, q.id).used_entry_id == entry.id

      # used: no longer offered, and not for another page
      assert (conn |> get(~p"/api/agent/context") |> json_response(200))["local_voices"] == []
    end

    test "a change of credit reaches every page; saying no takes the tips off",
         %{conn: conn, poet: poet} do
      local = local_fixture()
      q = answered(poet, local)
      entry = entry_fixture(poet)

      put_sections(conn, [
        %{kind: "local_tip", body: "Tiles.", metadata: %{local_question_id: q.id}}
      ])

      {:ok, local} = LocalVoices.set_consent(local, %{local_voice_credit: "anonymous"})
      [tip] = Journal.preload_entry(entry).sections

      assert LocalVoices.credit_text(tip.metadata["credit"]) ==
               "From a reader who lives in Lisbon"

      {:ok, _} = LocalVoices.set_consent(local, %{local_voice: false})
      assert Journal.preload_entry(entry).sections == []
    end

    test "purging a local takes their tips off other poets' pages", %{conn: conn, poet: poet} do
      local = local_fixture()
      q = answered(poet, local)
      entry = entry_fixture(poet)

      put_sections(conn, [
        %{kind: "local_tip", body: "Tiles.", metadata: %{local_question_id: q.id}}
      ])

      {:ok, _} = Purge.purge(local.id, local.email)
      assert Journal.preload_entry(entry).sections == []
    end

    test "the public page prints the credit, linked to the local's poet", %{
      conn: conn,
      poet: poet
    } do
      local = local_fixture(%{local_voice_credit: "poet"})
      poet_fixture(local, %{name: "Tobias Quill", slug: "tobias"})
      q = answered(poet, local)
      entry = published_entry_fixture(poet)

      put_sections(conn, [
        %{kind: "local_tip", body: "Tiles.", metadata: %{local_question_id: q.id}}
      ])

      html =
        build_conn()
        |> get(~p"/p/#{poet.slug}/#{Date.to_iso8601(entry.entry_date)}")
        |> html_response(200)

      assert html =~ "From Tobias Quill&#39;s companion, who lives in Lisbon"
      assert html =~ ~s(href="/p/tobias")
    end
  end
end
