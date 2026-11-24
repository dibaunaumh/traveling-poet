defmodule TravelingPoetWeb.NearHomeAwayWebTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, NearHome}
  alias TravelingPoetWeb.NearHomeComponents

  defmodule FakeSession do
    def run(user, note, _opts) do
      if pid = Process.whereis(:near_home_away_web_test),
        do: send(pid, {:session_run, user.id, note})

      {:ok, "Looking."}
    end
  end

  setup do
    Process.register(self(), :near_home_away_web_test)
    Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
    Application.put_env(:traveling_poet, :agent_session, FakeSession)

    Application.put_env(:traveling_poet, :reverse_geocoder, fn _lat, _lng ->
      {:ok, %{city: "Tel Aviv-Yafo", country: "Israel", country_code: "IL"}}
    end)

    on_exit(fn ->
      Application.delete_env(:traveling_poet, :sprites_client)
      Application.delete_env(:traveling_poet, :agent_session)
      Application.delete_env(:traveling_poet, :reverse_geocoder)
    end)

    user =
      agent_user_fixture(%{
        onboarding_completed: true,
        credits: 10,
        home_place_name: "Lisbon, Portugal",
        home_lat: 38.7223,
        home_lng: -9.1393
      })

    %{user: user, poet: poet_fixture(user, %{name: "Wren"})}
  end

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp away(user) do
    {:ok, user} =
      Accounts.update_user(user, %{
        away_aware: true,
        here_lat: 32.09,
        here_lng: 34.78,
        here_place_name: "Tel Aviv-Yafo, Israel",
        here_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    user
  end

  describe "POST /here" do
    test "reports where the reader is and starts a look around it", %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user(user, %{away_aware: true})

      body =
        conn
        |> signed_in(user)
        |> put_req_header("accept", "*/*")
        |> post(~p"/here", %{"lat" => "32.0853", "lng" => "34.7818"})
        |> json_response(200)

      assert body == %{"away" => true, "place" => "Tel Aviv-Yafo", "looking" => true}
      assert_receive {:session_run, _, note}, 2000
      assert note =~ "away from home"
    end

    test "refused until the reader switches it on", %{conn: conn, user: user} do
      conn =
        conn
        |> signed_in(user)
        |> put_req_header("accept", "*/*")
        |> post(~p"/here", %{"lat" => "32.0853", "lng" => "34.7818"})

      assert json_response(conn, 409) == %{"error" => "off"}
      assert Accounts.get_user!(user.id).here_lat == nil
    end

    test "nonsense is refused", %{conn: conn, user: user} do
      {:ok, user} = Accounts.update_user(user, %{away_aware: true})

      conn =
        conn
        |> signed_in(user)
        |> put_req_header("accept", "*/*")
        |> post(~p"/here", %{"lat" => "north", "lng" => "34.7818"})

      assert json_response(conn, 422)
    end

    test "signed out, it goes nowhere", %{conn: conn} do
      conn = post(conn, ~p"/here", %{"lat" => "32.0853", "lng" => "34.7818"})
      assert redirected_to(conn)
    end
  end

  test "the page reports only for a reader who switched it on", %{conn: conn, user: user} do
    {:ok, _view, html} = live(signed_in(conn, user), ~p"/guide/near")
    refute html =~ ~s(data-here="on")

    {:ok, _view, html} = live(signed_in(conn, away(user)), ~p"/guide/near")
    assert html =~ ~s(data-here="on")
  end

  describe "/guide/near" do
    test "offers to notice when away, and switching it on asks the device", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide/near")
      assert has_element?(view, "#near-away-offer")

      view |> element("#near-away-on") |> render_click()
      assert_push_event(view, "here:now", %{})
      assert Accounts.get_user!(user.id).away_aware
      refute has_element?(view, "#near-away-offer")
    end

    test "away with nothing found yet: the page is about where the reader is", %{
      conn: conn,
      user: user
    } do
      {:ok, _view, html} = live(signed_in(conn, away(user)), ~p"/guide/near")
      assert html =~ "within 40 km of Tel Aviv-Yafo"
      refute html =~ "within 40 km of Lisbon"
    end

    test "away with only home picks: says where the reader is and offers a look", %{
      conn: conn,
      user: user,
      poet: poet
    } do
      user = away(user)

      NearHome.replace_batch(user, poet, Date.utc_today(), [
        %{name: "Feira da Ladra", url: "https://example.com/feira", when_text: "Saturdays"}
      ])

      {:ok, view, _html} = live(signed_in(conn, user), ~p"/guide/near")
      assert has_element?(view, "#near-away", "You are in Tel Aviv-Yafo, away from home.")

      view |> element("#near-look-now") |> render_click()
      assert_receive {:session_run, _, note}, 2000
      assert note =~ "Tel Aviv-Yafo"
    end

    test "a batch found around the place says so, on the page and its cards", %{
      conn: conn,
      user: user,
      poet: poet
    } do
      user = away(user)

      picks =
        NearHome.replace_batch(user, poet, Date.utc_today(), [
          %{
            name: "Carmel Market",
            url: "https://example.com/carmel",
            when_text: "Sunday to Friday",
            distance_km: 2.3,
            around_name: "Tel Aviv-Yafo, Israel",
            around_lat: 32.09,
            around_lng: 34.78
          }
        ])

      {:ok, view, html} = live(signed_in(conn, user), ~p"/guide/near")
      assert html =~ "within 40 km of Tel Aviv-Yafo"
      assert html =~ "2.3 km from Tel Aviv-Yafo"
      refute html =~ "km from home"
      refute has_element?(view, "#near-away")

      card = render_component(&NearHomeComponents.near_home_card/1, picks: picks, poet: poet)
      assert card =~ "Wren found one thing around Tel Aviv-Yafo"
    end
  end

  describe "Settings" do
    test "the switch sits under the home city and tells the device", %{conn: conn, user: user} do
      {:ok, view, _html} = live(signed_in(conn, user), ~p"/settings")
      assert has_element?(view, "#away-setting", "Notice when I am away")

      view |> element("#away-toggle") |> render_click()
      assert_push_event(view, "here:now", %{})
      assert Accounts.get_user!(user.id).away_aware

      view |> element("#away-toggle") |> render_click()
      assert_push_event(view, "here:off", %{})
      refute Accounts.get_user!(user.id).away_aware
    end

    test "no home, no switch", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true})
      poet_fixture(user)
      {:ok, view, _html} = live(signed_in(conn, user), ~p"/settings")
      refute has_element?(view, "#away-setting")
    end
  end
end
