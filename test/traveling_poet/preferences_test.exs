defmodule TravelingPoet.PreferencesTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Preferences
  alias TravelingPoet.Preferences.Preference
  alias TravelingPoet.Repo

  defp poet, do: poet_fixture(user_fixture())

  defp age(pref, days) do
    at = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.truncate(:second)

    pref
    |> Ecto.Changeset.change(last_confirmed_at: at)
    |> Repo.update!()
  end

  test "confirming the same preference strengthens it rather than duplicating" do
    poet = poet()
    attrs = %{label: "more street food", dimension: "topic", polarity: "seek", source: "tap"}

    {:ok, first} = Preferences.record(poet.id, attrs)
    {:ok, second} = Preferences.record(poet.id, attrs)

    assert second.id == first.id
    assert second.weight == 2
    assert Repo.aggregate(Preference, :count) == 1
  end

  test "changing your mind flips the preference in place and remembers the old stance" do
    poet = poet()

    {:ok, _} =
      Preferences.record(poet.id, %{
        label: "more museums",
        dimension: "topic",
        polarity: "seek",
        source: "tap"
      })

    {:ok, flipped} =
      Preferences.record(poet.id, %{
        label: "more museums",
        dimension: "topic",
        polarity: "avoid",
        source: "tap"
      })

    assert flipped.polarity == "avoid"
    # weight resets: the new stance has been stated once, not three times
    assert flipped.weight == 1
    assert flipped.evidence["previous"]["polarity"] == "seek"
    assert Repo.aggregate(Preference, :count) == 1
  end

  test "a preference confirmed once fades, one confirmed repeatedly does not" do
    poet = poet()

    {:ok, passing} =
      Preferences.record(poet.id, %{label: "more rain poems", dimension: "tone", source: "tap"})

    {:ok, _} =
      Preferences.record(poet.id, %{label: "more markets", dimension: "topic", source: "tap"})

    {:ok, held} =
      Preferences.record(poet.id, %{label: "more markets", dimension: "topic", source: "tap"})

    age(passing, Preferences.stale_after_days() + 1)
    age(held, Preferences.stale_after_days() + 1)

    labels = Preferences.profile(poet.id) |> Enum.map(& &1.label)

    # This is what makes auto-apply safe: one tap is a nudge, repetition is a rule.
    refute "more rain poems" in labels
    assert "more markets" in labels
    # ...and the faded one is still listed in settings, not silently deleted
    assert Enum.any?(Preferences.list_active(poet.id), &(&1.label == "more rain poems"))
  end

  test "a dismissed preference resists inference but yields to the user" do
    poet = poet()

    {:ok, pref} =
      Preferences.record(poet.id, %{label: "more nightlife", dimension: "topic", source: "chat"})

    {:ok, _} = Preferences.dismiss(pref)

    # The poet overhearing it again must not quietly bring it back.
    {:ok, _} =
      Preferences.record(poet.id, %{label: "more nightlife", dimension: "topic", source: "chat"})

    assert Repo.get(Preference, pref.id).status == "dismissed"

    # The user tapping it themselves is a change of mind, and does.
    {:ok, _} =
      Preferences.record(poet.id, %{label: "more nightlife", dimension: "topic", source: "tap"})

    assert Repo.get(Preference, pref.id).status == "active"
  end

  test "the user's own words outrank an inferred paraphrase" do
    poet = poet()

    {:ok, _} =
      Preferences.record(poet.id, %{
        label: "seems to enjoy odd roadside attractions",
        dimension: "topic",
        source: "chat",
        key: "topic:roadside"
      })

    {:ok, updated} =
      Preferences.record(poet.id, %{
        label: "american stupid things",
        dimension: "topic",
        source: "tap",
        key: "topic:roadside"
      })

    assert updated.label == "american stupid things"
    assert updated.source == "tap"
    assert updated.weight == 2
  end

  test "the profile is capped and strongest-first" do
    poet = poet()

    for n <- 1..(Preferences.profile_limit() + 3) do
      {:ok, _} =
        Preferences.record(poet.id, %{label: "thing #{n}", dimension: "topic", source: "tap"})
    end

    {:ok, _} = Preferences.record(poet.id, %{label: "thing 1", dimension: "topic", source: "tap"})

    profile = Preferences.profile(poet.id)

    assert length(profile) == Preferences.profile_limit()
    assert hd(profile).label == "thing 1"
  end

  test "keys group by meaning, so re-phrasings of one answer don't stack up" do
    assert Preferences.derive_key("topic", "More Street Food!") == "topic:more-street-food"
    assert Preferences.derive_key("topic", "more street food") == "topic:more-street-food"
  end
end
