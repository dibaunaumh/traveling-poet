defmodule TravelingPoet.Preferences.CadenceTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Journal
  alias TravelingPoet.Preferences
  alias TravelingPoet.Preferences.{Cadence, EntryPrompt}
  alias TravelingPoet.Repo

  defp publish(poet, day_offset, attrs \\ %{}) do
    date = Date.add(Date.utc_today(), -day_offset)
    {:ok, entry} = Journal.upsert_entry(poet.id, date, Map.merge(%{title: "Day"}, attrs))
    {:ok, entry} = Journal.publish_entry(entry)
    entry
  end

  defp viewed(entry) do
    entry
    |> Ecto.Changeset.change(owner_viewed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end

  defp prompt(entry, attrs \\ %{}) do
    %EntryPrompt{}
    |> EntryPrompt.changeset(
      Map.merge(
        %{journal_entry_id: entry.id, question: "Which?", source: "app"},
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp stock_preferences(poet, n) do
    for i <- 1..n do
      {:ok, _} =
        Preferences.record(poet.id, %{label: "pref #{i}", dimension: "topic", source: "tap"})
    end
  end

  test "asks on the reader's first entries, when nothing is known yet" do
    poet = poet_fixture(user_fixture())
    entry = publish(poet, 0)

    assert {true, :cold_start} = Cadence.ask?(poet, entry)
  end

  test "never asks twice on the same entry" do
    poet = poet_fixture(user_fixture())
    entry = publish(poet, 0)
    prompt(entry)

    refute Cadence.ask?(poet, entry)
  end

  test "goes quiet once it knows enough, then asks again on the interval" do
    poet = poet_fixture(user_fixture())
    stock_preferences(poet, 3)

    # 4 earlier entries exist and were read, so this is neither cold start
    # nor disengagement
    for d <- 4..1//-1, do: publish(poet, d) |> viewed()
    quiet = publish(poet, 0)

    # 4 prior entries -> interval hit
    assert {true, :steady_state} = Cadence.ask?(poet, quiet)

    # a 5th prior entry -> off the interval
    other = publish(poet, 10)
    other = %{other | entry_date: Date.add(Date.utc_today(), 1)}
    refute Cadence.ask?(poet, other)
  end

  test "stays silent for a few days after the reader answers one" do
    poet = poet_fixture(user_fixture())
    stock_preferences(poet, 3)
    for d <- 4..1//-1, do: publish(poet, d) |> viewed()

    answered = publish(poet, 6) |> viewed()

    prompt(answered, %{
      answered_at: DateTime.utc_now() |> DateTime.truncate(:second),
      answer_option_id: "art"
    })

    today = publish(poet, 0)
    refute Cadence.ask?(poet, today)
  end

  test "backs off hard once prompts are being ignored" do
    poet = poet_fixture(user_fixture())
    stock_preferences(poet, 3)

    # three prompts shown, none acted on (but the entries were read)
    for d <- 3..1//-1, do: publish(poet, d) |> viewed() |> prompt()

    today = publish(poet, 0)
    # 3 prior entries: not a multiple of the backoff interval
    refute Cadence.ask?(poet, today)
  end

  test "a reader who has stopped opening entries gets one broader question" do
    poet = poet_fixture(user_fixture())
    stock_preferences(poet, 5)

    # plenty of history, all of it read...
    for d <- 9..4//-1, do: publish(poet, d) |> viewed()
    # ...then two that were never opened
    publish(poet, 3)
    publish(poet, 2)

    today = publish(poet, 0)

    assert {true, :disengaged} = Cadence.ask?(poet, today)
    assert Cadence.question_kind(:disengaged) == :broad
  end

  test "the first excursions into a topic always ask, and the question is the app's" do
    poet = poet_fixture(user_fixture())
    stock_preferences(poet, 5)
    for d <- 9..4//-1, do: publish(poet, d) |> viewed()

    topic = topic_fixture(poet, %{label: "Kit airplanes"})

    excursions =
      for d <- 3..0//-1 do
        entry = publish(poet, d)
        excursion_fixture(poet, topic, entry)
        Journal.preload_entry(entry)
      end

    [first, second, third, fourth] = excursions

    assert {true, :excursion} = Cadence.ask?(poet, first)
    assert {true, :excursion} = Cadence.ask?(poet, second)
    assert {true, :excursion} = Cadence.ask?(poet, third)
    assert Cadence.app_owned?(third)
    assert Cadence.question_kind(:excursion) == :excursion

    # the fourth falls back to the ordinary rules
    refute Cadence.app_owned?(fourth)

    case Cadence.ask?(poet, fourth) do
      {true, reason} -> refute reason == :excursion
      false -> :ok
    end

    # the poet cannot replace the app's question on those entries
    good = %{
      "question" => "More of this?",
      "options" => [%{"label" => "Yes"}, %{"label" => "No"}]
    }

    assert {:error, :app_owned} = Preferences.attach_agent_prompt(first, good)
    assert {:ok, _} = Preferences.attach_agent_prompt(fourth, good)
  end

  test "an engaged reader is not treated as disengaged" do
    poet = poet_fixture(user_fixture())
    stock_preferences(poet, 5)

    for d <- 5..1//-1, do: publish(poet, d) |> viewed()
    today = publish(poet, 0)

    case Cadence.ask?(poet, today) do
      {true, reason} -> refute reason == :disengaged
      false -> :ok
    end
  end
end
