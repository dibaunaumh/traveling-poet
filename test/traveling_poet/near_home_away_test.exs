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

  test "where the reader is never leaves through the change stream" do
    for field <- ~w(here_lat here_lng here_place_name here_at),
        do: assert(Serializer.redacted_field?("users", field))
  end

  test "short_name/1" do
    assert Away.short_name("Tel Aviv-Yafo, Israel") == "Tel Aviv-Yafo"
    assert Away.short_name(nil) == nil
  end
end
