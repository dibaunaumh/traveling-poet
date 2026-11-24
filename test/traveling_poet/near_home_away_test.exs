defmodule TravelingPoet.NearHomeAwayTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, NearHome, Usage}
  alias TravelingPoet.ChangeStream.Serializer
  alias TravelingPoet.NearHome.{Away, Pick}

  # Tel Aviv, from a reader whose home is Lisbon
  @tel_aviv {32.0853, 34.7818}

  defmodule FakeSession do
    def run(user, note, opts) do
      if pid = Process.whereis(:near_home_away_test),
        do: send(pid, {:session_run, user.id, note, opts})

      {:ok, "Four things around you."}
    end
  end

  setup do
    Process.register(self(), :near_home_away_test)
    Application.put_env(:traveling_poet, :agent_session, FakeSession)

    test_pid = self()

    Application.put_env(:traveling_poet, :reverse_geocoder, fn lat, lng ->
      send(test_pid, {:reverse, lat, lng})
      {:ok, %{city: "Tel Aviv-Yafo", country: "Israel", country_code: "IL"}}
    end)

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :agent_session)
      Application.delete_env(:traveling_poet, :reverse_geocoder)
    end)

    Req.Test.stub(TravelingPoet.LinkCheck, fn conn -> Req.Test.text(conn, "ok") end)

    user =
      user_fixture(%{
        credits: 10,
        onboarding_completed: true,
        away_aware: true,
        home_place_name: "Lisbon, Portugal",
        home_lat: 38.7223,
        home_lng: -9.1393
      })

    %{user: user, poet: poet_fixture(user)}
  end

  defp report(user, {lat, lng}), do: Away.report(user, lat, lng)

  defp in_tel_aviv(user, at \\ DateTime.utc_now()) do
    {:ok, user} =
      Accounts.update_user(user, %{
        here_lat: 32.09,
        here_lng: 34.78,
        here_place_name: "Tel Aviv-Yafo, Israel",
        here_at: DateTime.truncate(at, :second)
      })

    user
  end

  defp pick(attrs) do
    today = Date.to_iso8601(Date.utc_today())

    Map.merge(
      %{
        "name" => "Carmel Market",
        "url" => "https://example.com/carmel",
        "kind" => "market",
        "starts_on" => today,
        "ends_on" => today,
        "address" => "HaCarmel St, Tel Aviv",
        "lat" => 32.0684,
        "lng" => 34.7686,
        "blurb" => "Spices and fresh juice, busiest before Shabbat."
      },
      attrs
    )
  end

  describe "here/2" do
    test "away only when switched on, far from home and recently reported", %{user: user} do
      away = in_tel_aviv(user)
      assert %{name: "Tel Aviv-Yafo, Israel", away?: true, lat: 32.09} = Away.here(away)

      {:ok, off} = Accounts.update_user(away, %{away_aware: false})
      assert Away.here(off) == nil

      stale = in_tel_aviv(user, DateTime.add(DateTime.utc_now(), -8, :day))
      assert Away.here(stale) == nil

      {:ok, near_home} = Accounts.update_user(away, %{here_lat: 38.75, here_lng: -9.2})
      assert Away.here(near_home) == nil

      {:ok, homeless} = Accounts.update_user(away, %{home_lat: nil, home_lng: nil})
      assert Away.here(homeless) == nil
    end
  end

  describe "report/3" do
    test "stores a rounded point, names the town and starts a look around it", %{user: user} do
      assert {:ok, %{away?: true, place: "Tel Aviv-Yafo, Israel", looking?: true}} =
               report(user, @tel_aviv)

      assert_receive {:reverse, 32.09, 34.78}
      user = Accounts.get_user!(user.id)
      assert {user.here_lat, user.here_lng} == {32.09, 34.78}
      assert %DateTime{} = user.here_at

      assert_receive {:session_run, _, note, opts}, 2000
      assert opts[:channel] == "system"
      assert note =~ "away from home right now"
      assert note =~ "Tel Aviv-Yafo, Israel (32.0900, 34.7800)"
      assert note =~ "home is Lisbon, Portugal"
      assert note =~ "within 40 km of where they are"
      assert note =~ "What is on around Tel Aviv-Yafo?"
      refute note =~ "near home this week"
    end

    test "the same town again keeps its name and does not ask twice", %{user: user} do
      {:ok, _} = report(user, @tel_aviv)
      assert_receive {:reverse, _, _}
      assert_receive {:session_run, _, _, _}, 2000

      user = Accounts.get_user!(user.id)
      assert {:ok, %{away?: true, place: "Tel Aviv-Yafo, Israel"}} = report(user, {32.07, 34.79})
      refute_receive {:reverse, _, _}
      refute_receive {:session_run, _, _, _}, 200
      assert Usage.today_count(user.id, "near_home") == 1
    end

    test "near home is not away, and nothing starts", %{user: user} do
      assert {:ok, %{away?: false, looking?: false}} = report(user, {38.71, -9.14})
      refute_receive {:session_run, _, _, _}, 200
    end

    test "nothing is stored for a reader who did not switch it on", %{user: user} do
      {:ok, off} = Accounts.update_user(user, %{away_aware: false})
      assert report(off, @tel_aviv) == {:error, :off}
      assert Accounts.get_user!(user.id).here_lat == nil
    end

    test "a point that is not one is refused", %{user: user} do
      assert Away.report(user, 120.0, 10.0) == {:error, :invalid}
    end
  end

  describe "while away" do
    test "picks are measured from where the reader is and remember the place", %{
      user: user,
      poet: poet
    } do
      user = in_tel_aviv(user)

      lisbon =
        pick(%{
          "name" => "Feira da Ladra",
          "address" => "Campo de Santa Clara, Lisbon",
          "lat" => 38.7148,
          "lng" => -9.1263
        })

      assert {:ok, %{kept: [kept], dropped: [dropped]}} =
               NearHome.ingest(user, poet, [pick(%{}), lisbon])

      assert kept.name == "Carmel Market"
      assert kept.distance_km < 5
      assert kept.around_name == "Tel Aviv-Yafo, Israel"
      assert {kept.around_lat, kept.around_lng} == {32.09, 34.78}
      assert dropped.name == "Feira da Ladra"
    end

    test "a pick near home keeps no place", %{user: user, poet: poet} do
      lisbon =
        pick(%{
          "name" => "Feira da Ladra",
          "address" => "Campo de Santa Clara, Lisbon",
          "lat" => 38.7148,
          "lng" => -9.1263
        })

      assert {:ok, %{kept: [%Pick{around_name: nil, around_lat: nil}]}} =
               NearHome.ingest(user, poet, [lisbon])
    end

    test "due once per place: a batch around here settles it, one at home does not", %{
      user: user,
      poet: poet
    } do
      refute Away.due?(user)
      user = in_tel_aviv(user)

      home_today =
        pick(%{"name" => "Feira", "address" => "Lisbon", "lat" => 38.7148, "lng" => -9.1263})

      {:ok, home_user} = Accounts.update_user(user, %{away_aware: false})
      {:ok, %{kept: [_]}} = NearHome.ingest(home_user, poet, [home_today])
      assert Away.due?(user)
      assert NearHome.due?(user)

      {:ok, %{kept: [_]}} = NearHome.ingest(user, poet, [pick(%{})])
      refute Away.due?(user)
    end

    test "Near you switched off at home still looks around a reader away", %{
      user: user,
      poet: poet
    } do
      {:ok, user} = Accounts.update_user(in_tel_aviv(user), %{near_home: false})
      assert {:ok, :started} = NearHome.request(user, poet)
      assert_receive {:session_run, _, note, _}, 2000
      assert note =~ "Tel Aviv-Yafo"
    end

    test "switching off forgets where the reader was", %{user: user} do
      {:ok, user} = Away.set_enabled(in_tel_aviv(user), false)

      assert {user.away_aware, user.here_lat, user.here_place_name, user.here_at} ==
               {false, nil, nil, nil}
    end
  end

  describe "a trip on the calendar" do
    @jerusalem %{place_name: "Jerusalem, Israel", lat: 31.7683, lng: 35.2137, country_code: "IL"}

    defp connected(user) do
      {:ok, user} =
        Accounts.update_user(user, %{
          google_refresh_token: "refresh",
          google_scopes: [TravelingPoet.GoogleAuth.scope(:calendar)]
        })

      user
    end

    defp on_trip(user, until \\ Date.add(Date.utc_today(), 5)) do
      {:ok, user} = Away.calendar_moved(connected(user), Map.put(@jerusalem, :until, until))
      user
    end

    setup do
      Application.put_env(:traveling_poet, :near_home_enabled, true)
      on_exit(fn -> Application.delete_env(:traveling_poet, :near_home_enabled) end)
    end

    test "puts the reader there with no device at all, and Near you looks at once", %{
      user: user
    } do
      {:ok, user} = Accounts.update_user(user, %{away_aware: false})
      user = on_trip(user)

      assert %{name: "Jerusalem, Israel", source: :calendar, away?: true} = Away.here(user)
      assert NearHome.anchor(user).name == "Jerusalem, Israel"

      assert_receive {:session_run, _, note, _}, 2000
      assert note =~ "A trip on their calendar puts them in Jerusalem, Israel"
      assert note =~ "What is on around Jerusalem?"
    end

    test "the next sync on the same trip does not ask twice", %{user: user, poet: poet} do
      user = on_trip(user)
      assert_receive {:session_run, _, _, _}, 2000

      {:ok, %{kept: [_]}} =
        NearHome.ingest(user, poet, [
          pick(%{"address" => "Jaffa Gate, Jerusalem", "lat" => 31.7767, "lng" => 35.2275})
        ])

      _ = on_trip(user)
      refute_receive {:session_run, _, _, _}, 200
    end

    test "a device report from today beats it, an older one does not", %{user: user} do
      user = on_trip(user)

      older = in_tel_aviv(user, DateTime.add(DateTime.utc_now(), -2, :day))
      assert %{name: "Jerusalem, Israel"} = Away.here(older)

      assert %{name: "Tel Aviv-Yafo, Israel", source: :device} = Away.here(in_tel_aviv(user))

      {:ok, home_today} =
        Accounts.update_user(user, %{
          here_lat: 38.72,
          here_lng: -9.14,
          here_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert Away.here(home_today) == nil
    end

    test "counts only while the trip lasts, the calendar is connected and Near you is on", %{
      user: user
    } do
      {:ok, user} = Accounts.update_user(user, %{away_aware: false})

      ended = on_trip(user, Date.add(Date.utc_today(), -1))
      assert Away.here(ended) == nil

      user = on_trip(user)
      {:ok, disconnected} = Accounts.update_user(user, %{google_scopes: []})
      assert Away.here(disconnected) == nil

      {:ok, near_off} = Accounts.update_user(user, %{near_home: false})
      assert Away.here(near_off) == nil

      # the "notice when I am away" switch is consent enough
      {:ok, switch_on} = Accounts.update_user(near_off, %{away_aware: true})
      assert %{source: :calendar} = Away.here(switch_on)
    end

    test "no trip on forgets the place, and nothing starts", %{user: user} do
      user = on_trip(user)
      assert_receive {:session_run, _, _, _}, 2000

      {:ok, user} = Away.calendar_moved(user, nil)
      assert {user.trip_here_name, user.trip_here_lat, user.trip_here_until} == {nil, nil, nil}
      refute_receive {:session_run, _, _, _}, 200
    end
  end

  describe "an address the map does not know as written" do
    defp remember(query, lat, lng) do
      %TravelingPoet.Geocoder.CacheEntry{}
      |> TravelingPoet.Geocoder.CacheEntry.changeset(%{
        query_hash: TravelingPoet.Geocoder.CacheEntry.hash(query),
        query: query,
        found: true,
        lat: lat,
        lng: lng,
        looked_up_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> TravelingPoet.Repo.insert!()
    end

    test "is found by simpler forms: the venue, then the town", %{user: user, poet: poet} do
      user = in_tel_aviv(user)
      remember("Tel Aviv Museum of Art", 32.0773, 34.7869)
      remember("Ashdod", 31.8044, 34.6553)
      # a street of the same name far away is passed over, not taken
      remember("Mazal Dagim St.", 40.0, -74.0)

      museum =
        pick(%{
          "name" => "A Moment of Birth",
          "address" => "Tel Aviv Museum of Art, 27 Shaul Hamelech Blvd., Tel Aviv"
        })
        |> Map.drop(["lat", "lng"])

      festival =
        pick(%{"name" => "Festival", "address" => "Various venues, Ashdod"})
        |> Map.drop(["lat", "lng"])

      nowhere =
        pick(%{"name" => "Nhafa", "address" => "4 Mazal Dagim St., Old Jaffa"})
        |> Map.drop(["lat", "lng"])

      assert {:ok, %{kept: kept, dropped: [dropped]}} =
               NearHome.ingest(user, poet, [museum, festival, nowhere])

      assert Enum.map(kept, & &1.name) == ["A Moment of Birth", "Festival"]
      assert hd(kept).lat == 32.0773
      assert dropped.name == "Nhafa"
      assert dropped.reason =~ "km from Tel Aviv-Yafo"
    end
  end

  describe "a call written as text" do
    defmodule WritingSession do
      def run(_user, _note, _opts) do
        picks = [
          %{
            "name" => "Carmel Market",
            "url" => "https://example.com/carmel",
            "kind" => "market",
            "when_text" => "Sunday to Friday, until the afternoon",
            "address" => "HaCarmel St, Tel Aviv",
            "lat" => 32.0684,
            "lng" => 34.7686,
            "blurb" => "Spices {and} \"fresh\" juice."
          }
        ]

        {:ok, "[tool call] near_home_put(#{Jason.encode!(%{"picks" => picks})}) and then done"}
      end
    end

    test "is taken as the call when the turn saved nothing", %{user: user, poet: poet} do
      Application.put_env(:traveling_poet, :agent_session, WritingSession)
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")
      user = in_tel_aviv(user)

      assert {:ok, :started} = NearHome.request(user, poet)
      assert_receive {:near_home, :done}, 2000

      assert [%Pick{name: "Carmel Market", around_name: "Tel Aviv-Yafo, Israel"}] =
               NearHome.list(user.id)
    end

    test "is left alone once a real call landed, or when there is none", %{user: user, poet: poet} do
      user = in_tel_aviv(user)
      {:ok, %{kept: [_]}} = NearHome.ingest(user, poet, [pick(%{})])
      {:ok, written} = WritingSession.run(user, "", [])

      assert NearHome.rescue_written_call(user, poet, written) == :none
      assert NearHome.rescue_written_call(user, poet, "Four things around you.") == :none
      assert NearHome.rescue_written_call(user, poet, "near_home_put(not json)") == :none
    end
  end

  test "where the reader is never leaves through the change stream" do
    for field <-
          ~w(here_lat here_lng here_place_name here_at trip_here_name trip_here_lat trip_here_lng trip_here_until),
        do: assert(Serializer.redacted_field?("users", field))
  end

  test "short_name/1" do
    assert Away.short_name("Tel Aviv-Yafo, Israel") == "Tel Aviv-Yafo"
    assert Away.short_name(nil) == nil
  end
end
