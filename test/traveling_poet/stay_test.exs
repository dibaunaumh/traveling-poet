defmodule TravelingPoet.StayTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{DailyJourneyScheduler, Poets, Repo}
  alias TravelingPoet.Guide.{Stay, StayArea}

  defp scout_poet(user) do
    poet_fixture(user, %{
      current_place_name: "Kraków",
      current_lat: 50.0614,
      current_lng: 19.9366,
      arrived_at: DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second),
      settings: %{"mode" => "scout", "stay_duration_days" => 3}
    })
  end

  defp area(entry, attrs) do
    %StayArea{}
    |> StayArea.changeset(
      Map.merge(
        %{poet_id: entry.poet_id, journal_entry_id: entry.id, city: "Kraków", name: "Area"},
        attrs
      )
    )
    |> Repo.insert!()
  end

  describe "counting what is near" do
    test "places within a short walk, by kind; the pick first, then by count" do
      user = user_fixture()
      poet = scout_poet(user)
      entry = published_entry_fixture(poet)

      kazimierz =
        area(entry, %{name: "Kazimierz", lat: 50.0513, lng: 19.9465, position: 0})

      old_town =
        area(entry, %{
          name: "Old Town",
          lat: 50.0614,
          lng: 19.9366,
          recommended: true,
          position: 1
        })

      near = fn name, cat, lat, lng ->
        place_fixture(poet, entry, %{name: name, category: cat, lat: lat, lng: lng})
      end

      near.("Bakery", "cafe", 50.0517, 19.9470)
      near.("Bistro", "restaurant", 50.0509, 19.9460)
      near.("Shop", "shop", 50.0520, 19.9455)
      near.("Far away", "restaurant", 50.0900, 19.8000)

      pool = Stay.places_near(poet.id, [kazimierz, old_town])
      assert %{food: 2, shops: 1, sights: 0, total: 3} = Stay.near(kazimierz, pool)

      [first, second] = Stay.ranked([kazimierz, old_town], pool)
      assert first.area.name == "Old Town"
      assert second.area.name == "Kazimierz"
    end

    test "an area the map could not find counts nothing" do
      entry = published_entry_fixture(poet_fixture(user_fixture()))
      lost = area(entry, %{name: "Nowhere"})
      assert Stay.near(lost, []).total == 0
    end
  end

  describe "when the poet weighs where to stay" do
    test "the first plain day at a scout stop, once per city" do
      user = user_fixture()
      poet = scout_poet(user)

      plan = Poets.travel_plan(poet)
      assert plan.day == "stay"
      assert plan.stay_guide == %{city: "Kraków"}

      assert DailyJourneyScheduler.trigger_for(poet, plan) =~ "stay.md"

      entry = published_entry_fixture(poet)
      area(entry, %{name: "Kazimierz"})
      assert Poets.travel_plan(poet).stay_guide == nil
    end

    test "never for a wandering poet" do
      poet =
        poet_fixture(user_fixture(), %{
          current_place_name: "Kraków",
          arrived_at: DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
        })

      assert Poets.travel_plan(poet).stay_guide == nil
    end
  end

  describe "the agent puts its areas" do
    test "saved in order, capped, with what is near in the reply", %{conn: conn} do
      user = agent_user_fixture()
      poet = scout_poet(user)
      entry = entry_fixture(poet)

      areas =
        for n <- 1..7,
            do: %{"name" => "Area #{n}", "summary" => "S", "recommended" => n == 2}

      reply =
        conn
        |> put_req_header("authorization", "Bearer " <> user.agent_api_token)
        |> put(~p"/api/agent/journal_entries/#{Date.to_iso8601(entry.entry_date)}/stay_areas", %{
          areas: areas
        })
        |> json_response(200)

      assert reply["city"] == "Kraków"
      assert length(reply["areas"]) == Stay.max_areas()
      assert hd(reply["areas"])["recommended"]
      assert Repo.aggregate(StayArea, :count) == Stay.max_areas()
    end
  end

  test "the page gets a Where to stay spread with the areas ranked", %{conn: conn} do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = scout_poet(user)
    entry = published_entry_fixture(poet)

    area(entry, %{
      name: "Kazimierz",
      summary: "Cafes and courtyards.",
      best_for: "Your mornings",
      tradeoffs: "Busy at night",
      recommended: true,
      lat: 50.0513,
      lng: 19.9465
    })

    place_fixture(poet, entry, %{name: "Bakery", category: "cafe", lat: 50.0517, lng: 19.9470})

    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    date = Date.to_iso8601(entry.entry_date)

    {:ok, view, _html} = live(conn, ~p"/journal/#{date}")
    assert render(view) =~ "Where to stay"

    {:ok, view, _html} = live(conn, ~p"/journal/#{date}?spread=stay")
    assert has_element?(view, "#stay-#{entry.id}")
    assert has_element?(view, ".stay-area", "Kazimierz")
    assert has_element?(view, ".stay-pick")
    assert has_element?(view, ".stay-near", "1 place to eat")
  end
end
