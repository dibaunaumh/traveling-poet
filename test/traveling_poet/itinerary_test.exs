defmodule TravelingPoet.ItineraryTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Poets
  alias TravelingPoet.Poets.Poet

  setup do
    user = user_fixture()
    poet = poet_fixture(user, %{settings: %{"mode" => "scout"}})
    %{user: user, poet: poet}
  end

  test "mode helper defaults to wander and honors scout", %{poet: poet} do
    assert Poet.mode(poet) == "scout"
    assert Poet.mode(%Poet{settings: %{}}) == "wander"
    assert Poet.mode(%Poet{settings: nil}) == "wander"
  end

  test "stops append in order, advance, and mark visited", %{poet: poet} do
    {:ok, s1} = Poets.add_stop(poet.id, %{place_name: "Porto", lat: 41.15, lng: -8.61})
    {:ok, s2} = Poets.add_stop(poet.id, %{place_name: "Coimbra", lat: 40.2, lng: -8.42})

    assert [%{position: 0}, %{position: 1}] = Poets.list_stops(poet.id)
    assert Poets.next_pending_stop(poet.id).id == s1.id

    {:ok, _} = Poets.mark_stop_visited(poet.id, s1.id)
    assert Poets.next_pending_stop(poet.id).id == s2.id

    {:ok, _} = Poets.mark_stop_visited(poet.id, s2.id)
    assert Poets.next_pending_stop(poet.id) == nil
  end

  test "remove_stop only removes the poet's own stops", %{poet: poet} do
    other = poet_fixture(user_fixture())
    {:ok, other_stop} = Poets.add_stop(other.id, %{place_name: "X", lat: 1.0, lng: 1.0})

    assert {:error, :not_found} = Poets.remove_stop(poet.id, other_stop.id)
    assert length(Poets.list_stops(other.id)) == 1
  end

  test "poet_model policy: override beats scout beats fleet default" do
    alias TravelingPoet.Provisioner

    wander = %Poet{settings: %{}}
    scout = %Poet{settings: %{"mode" => "scout"}}
    override = %Poet{settings: %{"mode" => "scout", "model" => "custom/model-x"}}

    scout_model = Application.get_env(:traveling_poet, :scout_model)

    assert Provisioner.poet_model(wander) == Provisioner.openrouter_model()
    assert Provisioner.poet_model(scout) == scout_model
    assert Provisioner.poet_model(override) == "custom/model-x"
    assert Provisioner.poet_model(nil) == Provisioner.openrouter_model()

    # The precedence only means something while the two differ — config/runtime
    # pins them apart in test so this can't quietly become a tautology.
    refute scout_model == Provisioner.openrouter_model()
  end
end
