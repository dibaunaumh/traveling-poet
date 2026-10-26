defmodule TravelingPoet.NearHomeTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, NearHome, Repo, Topics, Usage}
  alias TravelingPoet.Geocoder.CacheEntry
  alias TravelingPoet.NearHome.Pick

  @today ~D[2026-10-22]

  # Reports the call and answers at once.
  defmodule FakeSession do
    def run(user, note, opts) do
      if pid = Process.whereis(:near_home_test),
        do: send(pid, {:session_run, user.id, note, opts})

      {:ok, "Three things near home this week."}
    end
  end

  setup do
    Process.register(self(), :near_home_test)
    Application.put_env(:traveling_poet, :agent_session, FakeSession)
    on_exit(fn -> Application.delete_env(:traveling_poet, :agent_session) end)

    # A link with "dead" in it is gone; every other one is alive.
    Req.Test.stub(TravelingPoet.LinkCheck, fn conn ->
      if conn.request_path =~ "dead",
        do: Plug.Conn.send_resp(conn, 404, "gone"),
        else: Req.Test.text(conn, "ok")
    end)

    user =
      user_fixture(%{
        credits: 10,
        home_place_name: "Lisbon, Portugal",
        home_lat: 38.7223,
        home_lng: -9.1393
      })

    %{user: user, poet: poet_fixture(user)}
  end

  defp pick(attrs) do
    Map.merge(
      %{
        "name" => "Feira da Ladra",
        "url" => "https://example.com/feira",
        "kind" => "market",
        "starts_on" => "2026-10-24",
        "ends_on" => "2026-10-24",
        "address" => "Campo de Santa Clara, Lisbon",
        "lat" => 38.7148,
        "lng" => -9.1263,
        "blurb" => "Old prints and tiles, early on Saturday."
      },
      attrs
    )
  end

  defp remember(query, lat, lng) do
    %CacheEntry{}
    |> CacheEntry.changeset(%{
      query_hash: CacheEntry.hash(query),
      query: query,
      found: true,
      lat: lat,
      lng: lng,
      looked_up_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert!()
  end

  describe "ingest/4" do
    test "keeps a pick near home, with its distance, and tells the reader's page", %{
      user: user,
      poet: poet
    } do
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")

      assert {:ok, %{kept: [kept], dropped: []}} =
               NearHome.ingest(user, poet, [pick(%{})], @today)

      assert kept.name == "Feira da Ladra"
      assert kept.kind == "market"
      assert kept.week_of == @today
      assert kept.starts_on == ~D[2026-10-24]
      assert kept.distance_km > 0.5 and kept.distance_km < 2.0
      assert_receive {:near_home, @today}

      assert [%Pick{name: "Feira da Ladra"}] = NearHome.latest(user.id)
      assert NearHome.last_batch_on(user.id) == @today
    end

    test "drops what it cannot stand behind, each with its reason", %{user: user, poet: poet} do
      remember("Rua das Flores 10, Porto", 41.1455, -8.6111)

      picks = [
        pick(%{"name" => "Gone", "url" => "https://example.com/dead-page"}),
        pick(%{"name" => "No link", "url" => nil}),
        pick(%{"name" => "Over", "starts_on" => "2026-10-10", "ends_on" => "2026-10-20"}),
        pick(%{"name" => "Too late", "starts_on" => "2026-11-20", "ends_on" => "2026-11-21"}),
        pick(%{"name" => "No when", "starts_on" => nil, "ends_on" => nil}),
        pick(%{
          "name" => "Porto",
          "lat" => nil,
          "lng" => nil,
          "address" => "Rua das Flores 10, Porto"
        }),
        pick(%{"name" => "Nowhere", "lat" => nil, "lng" => nil, "address" => "Nowhere Street 1"}),
        pick(%{
          "name" => "Open all week",
          "starts_on" => nil,
          "ends_on" => nil,
          "when_text" => "daily 10:00-18:00",
          "kind" => "gallery"
        })
      ]

      assert {:ok, %{kept: [kept], dropped: dropped}} = NearHome.ingest(user, poet, picks, @today)
      assert kept.name == "Open all week"
      assert kept.kind == "other"
      assert kept.when_text == "daily 10:00-18:00"

      reasons = Map.new(dropped, &{&1.name, &1.reason})
      assert reasons["Gone"] =~ "dead"
      assert reasons["No link"] =~ "url"
      assert reasons["Over"] =~ "over"
      assert reasons["Too late"] =~ "outside this week"
      assert reasons["No when"] =~ "dates"
      assert reasons["Porto"] =~ "km from home"
      assert reasons["Nowhere"] =~ "could not find"
    end

    test "coordinates far from home are checked against the address instead", %{
      user: user,
      poet: poet
    } do
      remember("Campo de Santa Clara, Lisbon", 38.7148, -9.1263)

      assert {:ok, %{kept: [kept]}} =
               NearHome.ingest(user, poet, [pick(%{"lat" => 48.85, "lng" => 2.35})], @today)

      assert_in_delta kept.lat, 38.7148, 0.0001
    end

    test "a resend replaces the day's list; a resend where all fail keeps it", %{
      user: user,
      poet: poet
    } do
      {:ok, _} = NearHome.ingest(user, poet, [pick(%{}), pick(%{"name" => "Second"})], @today)
      {:ok, _} = NearHome.ingest(user, poet, [pick(%{"name" => "Third"})], @today)
      assert Enum.map(NearHome.latest(user.id), & &1.name) == ["Third"]

      {:ok, %{kept: []}} = NearHome.ingest(user, poet, [pick(%{"url" => nil})], @today)
      assert Enum.map(NearHome.latest(user.id), & &1.name) == ["Third"]

      # Last week's batch stays in the list.
      next_week = %{"name" => "Next week", "starts_on" => "2026-10-31", "ends_on" => "2026-10-31"}
      {:ok, _} = NearHome.ingest(user, poet, [pick(next_week)], Date.add(@today, 7))
      assert Enum.map(NearHome.list(user.id), & &1.name) == ["Next week", "Third"]
    end

    test "a pick from an earlier week is turned back, so the poet finds something new", %{
      user: user,
      poet: poet
    } do
      {:ok, %{kept: [_]}} = NearHome.ingest(user, poet, [pick(%{})], @today)

      again = %{
        "name" => "  feira da  LADRA ",
        "starts_on" => "2026-10-31",
        "ends_on" => "2026-10-31"
      }

      fresh = %{"name" => "Something new", "starts_on" => "2026-10-31", "ends_on" => "2026-10-31"}

      assert {:ok, %{kept: [%Pick{name: "Something new"}], dropped: [dropped]}} =
               NearHome.ingest(user, poet, [pick(again), pick(fresh)], Date.add(@today, 7))

      assert dropped.reason =~ "already suggested the week of 2026-10-22"

      # Long enough ago, it may come round again
      later = Date.add(@today, 7 * 9)
      back = %{"starts_on" => Date.to_iso8601(later), "ends_on" => Date.to_iso8601(later)}
      assert {:ok, %{kept: [_], dropped: []}} = NearHome.ingest(user, poet, [pick(back)], later)
    end

    test "nothing is kept for a reader with no home", %{poet: poet} do
      user = user_fixture()
      assert NearHome.ingest(user, poet, [pick(%{})], @today) == {:error, :no_home}
    end

    test "a purged reader's picks go with them", %{user: user, poet: poet} do
      {:ok, _} = NearHome.ingest(user, poet, [pick(%{})], @today)
      assert {:ok, _} = Accounts.Purge.purge(user.id, user.email)
      assert Repo.aggregate(Pick, :count) == 0
    end
  end

  describe "request/3" do
    test "briefs the poet on home, radius, window, tastes and language", %{user: user, poet: poet} do
      {:ok, _} = Topics.create(poet.id, %{label: "Azulejos"})
      {:ok, user} = Accounts.update_user(user, %{locale: "he"})

      assert {:ok, :started} = NearHome.request(user, poet)
      assert_receive {:session_run, user_id, note, opts}, 2000
      assert user_id == user.id
      assert opts[:channel] == "system"
      assert note =~ "Lisbon, Portugal (38.7223, -9.1393)"
      assert note =~ "within 40 km"
      today = Date.utc_today()
      assert note =~ "between #{today} and #{Date.add(today, 10)}"
      assert note =~ "Azulejos"
      assert note =~ "in Hebrew"
      assert note =~ "near_home_put"
      assert Usage.today_count(user.id, "near_home") == 1
    end

    test "tells the poet what it suggested before, and what the reader saved and passed on", %{
      user: user,
      poet: poet
    } do
      last_week = Date.add(Date.utc_today(), -7)

      [saved, passed, _plain] =
        NearHome.replace_batch(user, poet, last_week, [
          %{name: "Fado at Tasca", url: "https://example.com/1", when_text: "Wednesdays"},
          %{name: "Tile workshop", url: "https://example.com/2", when_text: "Daily"},
          %{name: "Harbour walk", url: "https://example.com/3", when_text: "Daily"}
        ])

      {:ok, :saved} = TravelingPoet.Bookmarks.toggle(user.id, "near", saved.id)
      {:ok, :passed} = TravelingPoet.Bookmarks.toggle_pass(user.id, "near", passed.id)

      assert {:ok, :started} = NearHome.request(user, poet)
      assert_receive {:session_run, _, note, _}, 2000
      assert note =~ "do not suggest again: Fado at Tasca; Tile workshop; Harbour walk"
      assert note =~ "more like them: Fado at Tasca"
      assert note =~ "steer away: Tile workshop"
    end

    test "a first week's note has nothing to remember", %{user: user, poet: poet} do
      assert {:ok, :started} = NearHome.request(user, poet)
      assert_receive {:session_run, _, note, _}, 2000
      refute note =~ "earlier weeks"
      refute note =~ "They saved"
    end

    test "once a day, never without a home, and not while switched off", %{user: user, poet: poet} do
      assert {:ok, :started} = NearHome.request(user, poet)
      assert NearHome.request(user, poet) == {:error, :cap}

      assert NearHome.request(user_fixture(%{credits: 10}), poet) == {:error, :no_home}

      {:ok, off} = Accounts.update_user(user, %{near_home: false})
      assert NearHome.request(off, poet) == {:error, :off}
    end

    test "waits while another turn is out, except right after the daily run", %{
      user: user,
      poet: poet
    } do
      Usage.record(user.id, "daily_run_attempt")
      assert NearHome.request(user, poet) == {:error, :busy}
      assert {:ok, :started} = NearHome.request(user, poet, after_run: true)
    end
  end

  describe "after_publish/2" do
    setup do
      Application.put_env(:traveling_poet, :near_home_enabled, true)
      on_exit(fn -> Application.put_env(:traveling_poet, :near_home_enabled, false) end)
    end

    test "starts the week's turn when it is due", %{user: user, poet: poet} do
      Usage.record(user.id, "daily_run_attempt")
      assert NearHome.after_publish(user, poet) == :ok
      assert_receive {:session_run, _, _, _}, 2000
    end

    test "does nothing the week a batch already came", %{user: user, poet: poet} do
      {:ok, _} = NearHome.ingest(user, poet, [pick(%{})], Date.add(Date.utc_today(), -2))
      assert NearHome.after_publish(user, poet) == :ok
      refute_receive {:session_run, _, _, _}, 200
    end

    test "does nothing when switched off app-wide", %{user: user, poet: poet} do
      Application.put_env(:traveling_poet, :near_home_enabled, false)
      assert NearHome.after_publish(user, poet) == :ok
      refute_receive {:session_run, _, _, _}, 200
    end
  end
end
