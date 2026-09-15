defmodule TravelingPoet.TopicsTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Topics

  setup do
    user = user_fixture()
    poet = poet_fixture(user)
    %{poet: poet}
  end

  test "the companion's topics are active at once, in order", %{poet: poet} do
    {:ok, a} = Topics.create(poet.id, %{label: "Embodied minds", kind: "personal"})
    {:ok, b} = Topics.create(poet.id, %{label: "Kit airplanes"})

    assert a.status == "active"
    assert a.source == "settings"
    assert a.every_days == 7
    assert b.position == a.position + 1
    assert Enum.map(Topics.list(poet.id), & &1.id) == [a.id, b.id]
  end

  test "a proposal waits as proposed, and the same topic proposed twice is one", %{poet: poet} do
    {:ok, topic, false} =
      Topics.propose(poet.id, %{label: "Experimental music", evidence: %{"quote" => "I love it"}})

    assert topic.status == "proposed"
    assert topic.source == "chat"
    assert topic.key == "experimental-music"

    {:ok, again, true} = Topics.propose(poet.id, %{label: "experimental MUSIC!"})
    assert again.id == topic.id
    assert length(Topics.list(poet.id)) == 1
  end

  test "a proposal never changes what the companion decided", %{poet: poet} do
    {:ok, topic} = Topics.create(poet.id, %{label: "Kit airplanes"})
    {:ok, paused} = Topics.pause(topic)

    {:ok, same, true} = Topics.propose(poet.id, %{label: "Kit Airplanes"})
    assert same.id == paused.id
    assert same.status == "paused"
  end

  test "keeping a proposal activates it and marks it as the companion's", %{poet: poet} do
    {:ok, topic, false} = Topics.propose(poet.id, %{label: "Embodied minds"})
    {:ok, kept} = Topics.keep(topic)
    assert kept.status == "active"
    assert kept.source == "settings"
  end

  test "the agent payload carries active and proposed topics, never paused ones", %{poet: poet} do
    {:ok, active} = Topics.create(poet.id, %{label: "Kit airplanes"})
    {:ok, _proposed, false} = Topics.propose(poet.id, %{label: "Embodied minds"})
    {:ok, paused} = Topics.create(poet.id, %{label: "Ceramics"})
    {:ok, _} = Topics.pause(paused)

    payload = Topics.payload(poet.id)
    assert Enum.map(payload, & &1.label) == ["Kit airplanes", "Embodied minds"]
    assert Enum.map(payload, & &1.status) == ["active", "proposed"]
    assert hd(payload).id == active.id
  end

  test "labels are trimmed and bounded, cadence stays within range", %{poet: poet} do
    {:ok, topic} = Topics.create(poet.id, %{label: "  Ceramics  "})
    assert topic.label == "Ceramics"

    assert {:error, changeset} = Topics.create(poet.id, %{label: "x"})
    assert %{label: [_]} = errors_on(changeset)

    assert {:error, changeset} = Topics.update(topic, %{every_days: 1})
    assert %{every_days: [_]} = errors_on(changeset)

    assert {:error, changeset} = Topics.update(topic, %{kind: "hobby"})
    assert %{kind: [_]} = errors_on(changeset)
  end
end
