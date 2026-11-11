defmodule TravelingPoet.AiCHealthTest do
  # What Alice-in-Context is told so the fleet's day can answer "is the service
  # healthy": who was due, what a page holds and lacks, how a run really ended,
  # whether a notification went out, and what the reader made of the page.
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.AiCStub, only: [sent: 0, sent: 1]
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, AiC, Credits, DailyJourneyScheduler, Email, Journal, Poets}
  alias TravelingPoet.{Repo, Telegram, Usage, WebPush}
  alias TravelingPoet.AiC.{ReadTally, Roster}
  alias TravelingPoet.Email.Notifier

  setup do
    TravelingPoet.AiCStub.start()
  end

  defp page(poet, date \\ Date.utc_today(), body \\ "salt diesel bread") do
    {:ok, entry} = Journal.upsert_entry(poet.id, date, %{title: "A day", place_name: "Lisbon"})
    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: body}])
    {:ok, entry} = Journal.publish_entry(entry)
    entry
  end

  # Set out yesterday, hour pinned to 00:00 UTC, ten credits.
  defp set_out(attrs \\ %{}, user_attrs \\ %{}) do
    user = user_fixture(Map.merge(%{sprite_provisioned: true, credits: 10}, user_attrs))

    poet =
      poet_fixture(
        user,
        Map.merge(%{status: "active", settings: %{"journal_hour_utc" => 0}}, attrs)
      )

    entry = published_entry_fixture(poet, %{entry_date: Date.add(Date.utc_today(), -1)})
    yesterday = DateTime.add(DateTime.utc_now(:second), -1, :day)
    entry |> Ecto.Changeset.change(published_at: yesterday) |> Repo.update!()
    sent()
    {Accounts.get_user!(user.id), poet}
  end

  defp attempt(user, poet, minutes_ago) do
    {:ok, a} = Usage.record(user.id, "daily_run_attempt")
    at = DateTime.utc_now(:second) |> DateTime.add(-minutes_ago, :minute)
    a = a |> Ecto.Changeset.change(occurred_at: at) |> Repo.update!()
    {:ok, _} = Credits.debit_daily_run(user, poet, a.id)
    a
  end

  describe "the page" do
    test "is published with what it holds and what it lacks" do
      poet = poet_fixture(user_fixture())
      entry = page(poet)
      AiC.journal_published(entry)

      assert [ev] = sent("journal_published")
      assert ev["id"] =~ ~r/^evt_published_entry-#{entry.id}_[0-9a-f]{8}$/
      assert ev["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
      assert ev["body"] == %{"text" => "A day"}

      assert ev["metadata"]["page"] == %{
               "parts" => [%{"id" => "story", "words" => 3}],
               "missing" => ["places", "drawing"]
             }
    end

    test "is reported again when it gains its places and its drawing, and only then" do
      user = user_fixture()
      poet = poet_fixture(user)
      entry = page(poet)
      AiC.journal_published(entry)
      [first] = sent("journal_published")

      # nothing changed: the same event, which the server drops
      AiC.page_changed(user.id, entry.entry_date)
      assert [same] = sent("journal_published")
      assert same["id"] == first["id"]

      place_fixture(poet, entry)
      media_fixture(poet, %{journal_entry_id: entry.id})
      AiC.page_changed(user.id, Date.to_iso8601(entry.entry_date))

      assert [second] = sent("journal_published")
      assert second["id"] != first["id"]
      assert second["body"] == first["body"]
      assert second["metadata"]["page"]["missing"] == []

      assert %{"id" => "places", "count" => 1} in second["metadata"]["page"]["parts"]
      assert %{"id" => "drawing", "count" => 1} in second["metadata"]["page"]["parts"]
    end

    test "an old page that is edited is left alone" do
      user = user_fixture()
      poet = poet_fixture(user)
      entry = page(poet, Date.add(Date.utc_today(), -5))
      long_ago = DateTime.add(DateTime.utc_now(:second), -3, :day)
      entry |> Ecto.Changeset.change(published_at: long_ago) |> Repo.update!()
      sent()

      assert AiC.page_changed(user.id, entry.entry_date) == :skipped
      assert AiC.page_changed(user.id, "not a date") == :skipped
      assert AiC.page_changed(user.id, ~D[2020-01-01]) == :skipped
      assert sent("journal_published") == []
    end
  end

  describe "the roster" do
    test "names every poet that has set out, due or not, and leaves out one still writing entry #0" do
      {_, due} = set_out(%{name: "Hilma"})
      {_, paused} = set_out(%{name: "Basho", status: "paused"})
      {_, broke} = set_out(%{name: "Emily"}, %{credits: nil})
      {_, exempt} = set_out(%{name: "Rumi"}, %{credits: nil, quota_exempt: true})
      poet_fixture(user_fixture(%{sprite_provisioned: true, credits: 10}), %{status: "active"})

      now = DateTime.utc_now(:second)
      roster = Map.new(Roster.entries(now), fn {poet, entry} -> {poet.id, entry} end)

      assert Map.keys(roster) |> Enum.sort() ==
               Enum.sort([due.id, paused.id, broke.id, exempt.id])

      assert %{status: "due", reason: nil, credits: 10.0} = roster[due.id]
      assert roster[due.id].date == DateTime.to_date(now)
      assert roster[due.id].due_at == DateTime.new!(DateTime.to_date(now), ~T[00:00:00])

      assert %{status: "paused", reason: "paused"} = roster[paused.id]
      assert %{status: "no_credits", reason: "out of credits", credits: +0.0} = roster[broke.id]
      assert %{status: "due", credits: nil} = roster[exempt.id]
    end

    test "is announced once a poet, and again when a poet stops being due" do
      {_, poet} = set_out(%{name: "Hilma"})
      now = DateTime.utc_now(:second)

      seen = Roster.announce(%{}, now)
      assert [ev] = sent("expected")
      assert ev["actor"]["id"] == "poet-#{poet.id}"
      assert ev["type"] == "activity"
      assert ev["body"] == %{"text" => "due at 00:00 UTC"}
      assert ev["hints"]["address"] == "Operate/inner/Fleet/poet-#{poet.id}/travel_n_journal"
      assert ev["metrics"] == %{"credits" => 10.0}

      assert ev["metadata"] == %{
               "status" => "due",
               "due_at" => DateTime.to_iso8601(DateTime.new!(DateTime.to_date(now), ~T[00:00:00]))
             }

      assert Roster.announce(seen, now) == seen
      assert sent("expected") == []

      {:ok, _} = Poets.update_poet(poet, %{status: "paused"})
      seen = Roster.announce(seen, now)
      assert seen[poet.id] == {DateTime.to_date(now), "paused"}

      assert [ev] = sent("expected")
      assert ev["metadata"]["status"] == "paused"
      assert ev["body"] == %{"text" => "not due: paused"}
    end

    test "a page already out settles the day, even for a poet paused since" do
      {_, poet} = set_out(%{name: "Hilma"})
      page(poet)
      {:ok, _} = Poets.update_poet(poet, %{status: "paused"})

      assert [{_, %{status: "due"}}] = Roster.entries()
    end

    test "says nothing and asks nothing when AiC is not configured" do
      set_out()
      Application.delete_env(:alice_in_context, :token)
      assert Roster.announce(%{}) == %{}
    end

    test "a poet is due at its hour, or later when yesterday's run ended late" do
      {user, poet} = set_out()
      today = Date.utc_today()
      now = DateTime.new!(today, ~T[12:00:00])
      assert DailyJourneyScheduler.due_at(poet, now) == DateTime.new!(today, ~T[00:00:00])

      {:ok, run} = Usage.record(user.id, "daily_run")
      late = DateTime.new!(Date.add(today, -1), ~T[23:00:00])
      run |> Ecto.Changeset.change(occurred_at: late) |> Repo.update!()

      assert DailyJourneyScheduler.due_at(poet, now) == DateTime.new!(today, ~T[21:00:00])
    end
  end

  describe "a daily run" do
    test "is an error when nothing was published, whatever the turn said" do
      {user, poet} = set_out()

      AiC.daily_run(user.id, poet, {:ok, "done"})
      AiC.daily_run(user.id, poet, {:ok, "done"}, published: false, attempt: 7, retry: true)
      AiC.daily_run(user.id, poet, {:timeout, nil}, published: false)
      AiC.daily_run(user.id, poet, {:error, :closed}, published: true)

      assert [ok, silent, stalled, late] = sent("daily_run")
      assert ok["type"] == "activity" and ok["body"] == %{"text" => "published"}
      assert ok["recipient"]["id"] == "poet-#{poet.id}"

      assert silent["type"] == "error"
      assert silent["id"] == "evt_daily_run_attempt-7"
      assert silent["body"] == %{"text" => "failed: finished its turn without publishing"}
      assert %{"published" => false, "attempt" => 7, "retry" => true} = silent["metadata"]

      assert stalled["type"] == "error"
      assert stalled["body"] == %{"text" => "timed out with nothing published"}

      assert late["type"] == "activity"
      assert late["body"] == %{"text" => "published, then the turn failed"}
    end

    test "that ends well without a page is reported as failed and refunded" do
      {user, poet} = set_out()
      a = attempt(user, poet, 5)
      started = DateTime.add(DateTime.utc_now(), -5, :minute)

      DailyJourneyScheduler.finish_run(user, poet, a, started, {:ok, "I published it"}, true)

      assert [ev] = sent("daily_run")
      assert ev["type"] == "error"
      assert ev["id"] == "evt_daily_run_attempt-#{a.id}"
      assert ev["metadata"]["retry"] == true
      assert sent("journal_published") == []
    end

    test "that published tells the outcome, and the page as it stands at the end" do
      {user, poet} = set_out()
      a = attempt(user, poet, 5)
      started = DateTime.add(DateTime.utc_now(), -5, :minute)
      entry = page(poet)
      AiC.journal_published(entry)
      [first] = sent("journal_published")
      # the places came after the publish call, as they usually do
      place_fixture(poet, entry)

      DailyJourneyScheduler.finish_run(user, poet, a, started, {:error, :closed}, false)

      events = sent()
      assert [run] = Enum.filter(events, &(&1["verb"] == "daily_run" and &1["type"] != "metric"))
      assert run["type"] == "activity"
      assert run["body"] == %{"text" => "published, then the turn failed"}
      assert %{"published" => true, "retry" => false} = run["metadata"]

      assert [again] = Enum.filter(events, &(&1["verb"] == "journal_published"))
      assert again["id"] != first["id"]
      assert again["metadata"]["page"]["missing"] == ["drawing"]
    end

    test "cut off by a deploy is reported when it is settled" do
      {user, poet} = set_out()
      a = attempt(user, poet, 30)

      DailyJourneyScheduler.settle_interrupted(DateTime.utc_now(:second))

      assert [ev] = sent("daily_run")
      assert ev["type"] == "error"
      assert ev["id"] == "evt_daily_run_attempt-#{a.id}"
      assert ev["body"] == %{"text" => "failed: interrupted with nothing published"}
    end
  end

  describe "the email of a page" do
    setup do
      Application.put_env(:traveling_poet, :resend_api_key, "re_test")
      on_exit(fn -> Application.delete_env(:traveling_poet, :resend_api_key) end)

      user = user_fixture(%{email: "mani@example.com"})
      poet = poet_fixture(user, %{name: "Kenji"})
      entry = page(poet, ~D[2026-09-30])
      sent()
      %{user: user, poet: poet, entry: entry}
    end

    defp resend(status) do
      test = self()

      Req.Test.stub(Email, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:resend, Jason.decode!(body)})
        Req.Test.json(%Plug.Conn{conn | status: status}, %{"id" => "email-1"})
      end)
    end

    test "that went out is a delivery, and its link says it came from the email",
         %{user: user, poet: poet, entry: entry} do
      resend(200)
      Notifier.send_entry(poet.id, entry.id)

      assert_receive {:resend, mail}
      assert mail["html"] =~ "/journal/2026-09-30?via=email"
      assert mail["text"] =~ "/journal/2026-09-30?via=email"

      assert [ev] = sent("deliver")
      assert ev["type"] == "activity"
      assert ev["actor"]["id"] == "poet-#{poet.id}"
      assert ev["recipient"]["id"] == "user-#{user.id}"
      assert ev["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
      assert ev["metadata"] == %{"channel" => "email", "status" => "sent"}
    end

    test "that the relay refused is a failed delivery, with a reason that names no address",
         %{poet: poet, entry: entry} do
      resend(500)
      Notifier.send_entry(poet.id, entry.id)

      assert [ev] = sent("deliver")
      assert ev["type"] == "error"

      assert ev["metadata"] == %{
               "channel" => "email",
               "status" => "failed",
               "reason" => "http 500"
             }
    end

    test "that the reader turned off is a delivery skipped, not a silence",
         %{user: user, poet: poet, entry: entry} do
      {:ok, _} = Accounts.update_user(user, %{email_notify: false})
      resend(200)
      Notifier.send_entry(poet.id, entry.id)

      refute_received {:resend, _}
      assert [ev] = sent("deliver")
      assert ev["type"] == "activity"

      assert ev["metadata"] == %{
               "channel" => "email",
               "status" => "skipped",
               "reason" => "turned off"
             }
    end
  end

  describe "the other channels" do
    setup do
      user = user_fixture()
      poet = poet_fixture(user)
      entry = page(poet, ~D[2026-09-30])
      sent()
      %{user: user, poet: poet, entry: entry}
    end

    defp device(user, endpoint) do
      {ua_public, _} = :crypto.generate_key(:ecdh, :prime256v1)

      {:ok, _} =
        WebPush.subscribe(user, %{
          "endpoint" => endpoint,
          "keys" => %{
            "p256dh" => WebPush.Crypto.b64(ua_public),
            "auth" => WebPush.Crypto.b64(:crypto.strong_rand_bytes(16))
          }
        })
    end

    test "a push that reached a device is a delivery", %{user: user, poet: poet, entry: entry} do
      device(user, "https://push.example/phone")
      Req.Test.stub(WebPush, fn conn -> Plug.Conn.send_resp(conn, 201, "") end)

      assert {1, 0} = WebPush.notify_entry(poet.id, entry.id)

      assert [ev] = sent("deliver")
      assert ev["recipient"]["id"] == "user-#{user.id}"
      assert ev["metadata"] == %{"channel" => "push", "status" => "sent"}
    end

    test "a push to a device that is gone is a failed delivery; no device at all says nothing",
         %{user: user, poet: poet, entry: entry} do
      assert {0, 0} = WebPush.notify_entry(poet.id, entry.id)
      assert sent("deliver") == []

      device(user, "https://push.example/dead")
      Req.Test.stub(WebPush, fn conn -> Plug.Conn.send_resp(conn, 410, "") end)
      assert {0, 1} = WebPush.notify_entry(poet.id, entry.id)

      assert [ev] = sent("deliver")
      assert ev["type"] == "error"

      assert ev["metadata"] == %{
               "channel" => "push",
               "status" => "failed",
               "reason" => "subscription gone"
             }
    end

    test "a paired Telegram chat that asked for quiet is a delivery skipped",
         %{user: user, poet: poet, entry: entry} do
      user |> Ecto.Changeset.change(telegram_chat_id: 4242) |> Repo.update!()
      {:ok, _} = Poets.update_poet(poet, %{settings: %{"telegram_notify" => false}})

      Telegram.Notifier.handle_info({:journal_published, poet.id, entry.id}, %{})

      assert [ev] = sent("deliver")

      assert ev["metadata"] == %{
               "channel" => "telegram",
               "status" => "skipped",
               "reason" => "turned off"
             }
    end

    test "a reader with no Telegram chat has no such channel, and nothing is said",
         %{poet: poet, entry: entry} do
      Telegram.Notifier.handle_info({:journal_published, poet.id, entry.id}, %{})
      assert sent("deliver") == []
    end
  end

  test "a notification link carries its channel, before any fragment" do
    assert AiC.via("/journal/2026-09-11", "push") == "/journal/2026-09-11?via=push"

    assert AiC.via("https://poet.travel/p/kenji/2026-09-11?spread=places#top", "telegram") ==
             "https://poet.travel/p/kenji/2026-09-11?spread=places&via=telegram#top"
  end

  describe "what the reader made of the page" do
    setup do
      user = user_fixture()
      poet = poet_fixture(user)
      entry = page(poet)
      sent()
      %{user: user, poet: poet, entry: entry}
    end

    test "time on a part adds up and is sent once, in seconds",
         %{user: user, poet: poet, entry: entry} do
      ReadTally.add(user, entry, "story", 20_000)
      ReadTally.add(user, entry, "story", 14_400)
      ReadTally.add(user, entry, "places", 0)
      ReadTally.add(user, entry, nil, 9_000)

      reads = sent("read") |> Enum.sort_by(& &1["metadata"]["part"])
      assert [places, story] = reads
      assert story["actor"]["id"] == "user-#{user.id}"
      assert story["recipient"]["id"] == "poet-#{poet.id}"
      assert story["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
      assert story["metadata"] == %{"channel" => "owner", "part" => "story"}
      assert story["metrics"] == %{"seconds" => 34}
      # opened and left at once: seen, for no time
      assert places["metrics"] == %{"seconds" => 0}

      assert sent("read") == []
    end

    test "a marker says praise or complaint, and which part it is on",
         %{user: user, entry: entry} do
      AiC.marker_added(user.id, entry.id, %{kind: "boring", section_kind: "description"})
      AiC.marker_added(user.id, entry.id, %{"kind" => "beautiful", "target" => "illustration"})
      AiC.marker_added(user.id, entry.id, %{kind: "more_details", section_kind: "art_culture"})

      assert [boring, beautiful, more] = sent("marker")
      assert boring["type"] == "feedback"

      assert boring["metadata"] == %{
               "kind" => "boring",
               "sentiment" => "negative",
               "part" => "story"
             }

      assert beautiful["metadata"] == %{
               "kind" => "beautiful",
               "sentiment" => "positive",
               "part" => "drawing"
             }

      assert more["metadata"] == %{"kind" => "more_details", "part" => "notes"}
    end

    test "a reaction is feedback on the page", %{user: user, poet: poet, entry: entry} do
      AiC.reaction(user, entry, "not_for_me")
      AiC.reaction(user, entry, "love")

      assert [no, yes] = sent("reaction")
      assert no["type"] == "feedback"
      assert no["recipient"]["id"] == "poet-#{poet.id}"
      assert no["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
      assert no["metadata"] == %{"kind" => "not_for_me", "sentiment" => "negative"}
      assert yes["metadata"]["sentiment"] == "positive"
    end

    test "a note to the team written on a page is about that page",
         %{user: user, entry: entry} do
      date = Date.to_iso8601(entry.entry_date)
      AiC.feedback_message(user.id, "the map is empty", kind: "broken", page: "/journal/#{date}")
      AiC.feedback_message(user.id, "love it", kind: "idea", page: "/settings")

      assert [broken, idea] = sent("feedback")
      assert broken["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
      assert broken["metadata"] == %{"kind" => "broken", "sentiment" => "negative"}
      assert idea["subjects"] in [nil, []]
      assert idea["metadata"] == %{"kind" => "idea"}
    end

    test "a score asked after a page is about that page", %{user: user, entry: entry} do
      AiC.nps(user.id, 4, entry.id)
      AiC.nps(user.id, 9)

      assert [low, high] = sent("nps")
      assert low["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
      assert low["metrics"] == %{"score" => 4}
      assert high["subjects"] in [nil, []]
    end
  end

  test "a tool call says what it was asked, in short" do
    user = user_fixture()
    poet_fixture(user)
    sent()

    AiC.tool_event(user.id, %{
      "name" => "web_search",
      "phase" => "start",
      "toolCallId" => "c9",
      "args" => %{
        "query" => "tram 28 timetable",
        "count" => 5,
        "nested" => %{"a" => 1},
        "prompt" => String.duplicate("x", 500)
      }
    })

    assert [ev] = sent()
    args = ev["metadata"]["args"]
    assert args["query"] == "tram 28 timetable"
    assert args["count"] == 5
    refute Map.has_key?(args, "nested")
    assert String.length(args["prompt"]) <= 160
  end
end
