defmodule TravelingPoet.BooksTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{
    Accounts,
    Books,
    Credits,
    DailyJourneyScheduler,
    Journal,
    Poets,
    Repo,
    Usage
  }

  alias TravelingPoet.Books.{Composer, Edition}
  alias TravelingPoet.Credits.CreditTransaction

  # Test pricing (runtime.exs): base 2 + 1 per chapter, capped at 5.
  defp setup_journey(user_attrs \\ %{}) do
    user = agent_user_fixture(Map.merge(%{credits: 10}, user_attrs))
    poet = poet_fixture(user, %{name: "Wren", status: "active"})
    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
    entry = published_entry_fixture(poet, %{title: "Trams"})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{
          kind: "description",
          body: "Lisbon is built on hills and the trams take them personally."
        },
        %{
          kind: "poem",
          title: "Tram 28",
          body: "Yellow box, iron song,\nyou take the hill the way"
        }
      ])

    {Accounts.get_user!(user.id), poet, entry}
  end

  defp ledger(user, kind),
    do: Repo.all(from t in CreditTransaction, where: t.user_id == ^user.id and t.kind == ^kind)

  test "the cost follows the journey's size and never passes the cap" do
    assert Credits.book_compose_cost(0) == 2_000
    assert Credits.book_compose_cost(1) == 3_000
    assert Credits.book_compose_cost(3) == 5_000
    assert Credits.book_compose_cost(40) == 5_000
  end

  describe "request_composition/2" do
    test "charges up front, opens an edition and records the attempt" do
      {user, poet, _entry} = setup_journey()

      assert {:ok,
              %Edition{status: "composing", chapter_count: 1, credits_charged: 3_000} = edition} =
               Books.request_composition(user, poet)

      assert [tx] = ledger(user, "debit_book_compose")
      assert tx.amount == -3_000
      assert tx.reference == "book_compose:#{edition.id}"
      assert Credits.balance(Accounts.get_user!(user.id)) == 7_000
      assert Usage.today_count(user.id, "book_compose_attempt") == 1
      assert Books.composing?(poet)
    end

    test "an exempt account composes for free and leaves no ledger row" do
      {user, poet, _entry} = setup_journey(%{quota_exempt: true, credits: nil})

      assert {:ok, %Edition{credits_charged: 0}} = Books.request_composition(user, poet)
      assert ledger(user, "debit_book_compose") == []
    end

    test "each blocker is named, and none of them charges anything" do
      {user, poet, _entry} = setup_journey()

      # already composing
      {:ok, _} = Books.request_composition(user, poet)
      user = Accounts.get_user!(user.id)
      assert {:blocked, :already_composing} = Books.request_composition(user, poet)
      assert length(ledger(user, "debit_book_compose")) == 1

      # not enough credits
      poor = agent_user_fixture(%{credits: 2})
      poor_poet = poet_fixture(poor)
      published_entry_fixture(poor_poet)
      assert {:blocked, :insufficient_credits} = Books.request_composition(poor, poor_poet)
      assert Repo.all(from e in Edition, where: e.poet_id == ^poor_poet.id) == []

      # nothing published yet
      empty = agent_user_fixture(%{credits: 10})
      assert {:blocked, :empty} = Books.request_composition(empty, poet_fixture(empty))

      # no sprite yet
      new = user_fixture(%{credits: 10})
      new_poet = poet_fixture(new)
      published_entry_fixture(new_poet)
      assert {:blocked, :no_sprite} = Books.request_composition(new, new_poet)
    end

    test "the daily cap counts attempts, and a busy poet is not interrupted" do
      {user, poet, _entry} = setup_journey()
      {:ok, _} = Usage.record(user.id, "book_compose_attempt")
      {:ok, _} = Usage.record(user.id, "book_compose_attempt")
      assert {:blocked, :daily_cap} = Books.request_composition(user, poet)

      {user2, poet2, _} = setup_journey()
      {:ok, _} = Usage.record(user2.id, "daily_run_attempt")
      assert {:blocked, :poet_busy} = Books.request_composition(user2, poet2)
    end
  end

  describe "the poet writing into its edition" do
    test "put_matter is refused unless a composition is open" do
      {_user, poet, _entry} = setup_journey()
      assert {:error, :not_composing} = Books.put_matter(poet, %{"dedication" => "For you"})
    end

    test "put_matter lands in the open edition and verifies quotes" do
      {user, poet, entry} = setup_journey()
      {:ok, _edition} = Books.request_composition(user, poet)

      {:ok, edition, report} =
        Books.put_matter(poet, %{
          "dedication" => "For you",
          "pull_quotes" => [
            %{
              "entry_date" => Date.to_iso8601(entry.entry_date),
              "text" => "you take the hill the way"
            },
            %{
              "entry_date" => Date.to_iso8601(entry.entry_date),
              "text" => "a line I never wrote at all"
            }
          ]
        })

      assert edition.matter["dedication"] == "For you"
      assert length(report.accepted_quotes) == 1
      assert length(report.dropped_quotes) == 1
    end
  end

  describe "Composer.finish/2" do
    test "words landed: ready, kept, announced, even if the socket dropped afterwards" do
      {user, poet, _entry} = setup_journey()
      {:ok, edition} = Books.request_composition(user, poet)
      {:ok, _, _} = Books.put_matter(poet, %{"foreword" => "Before the road."})

      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "books")
      Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "user:#{user.id}")

      assert %Edition{status: "ready", composed_at: %DateTime{}} =
               Composer.finish(edition.id, {:timeout, "and then I"})

      assert_receive {:book_ready, user_id, edition_id}
      assert {user_id, edition_id} == {user.id, edition.id}
      assert_receive {:book_edition_updated, ^edition_id}

      assert ledger(user, "refund") == []
      assert Usage.today_count(user.id, "book_compose") == 1
      refute Books.composing?(poet)
      assert Books.latest_ready_edition(poet).id == edition.id
    end

    test "nothing landed: failed and refunded, once, however often it is settled" do
      {user, poet, _entry} = setup_journey()
      {:ok, edition} = Books.request_composition(user, poet)
      # only openers: not a composed edition
      {:ok, _, _} = Books.put_matter(poet, %{"epilogue" => "After."})

      assert %Edition{status: "failed", error: "the turn ended without writing the book's matter"} =
               Composer.finish(edition.id, {:ok, "Here is your foreword: ..."})

      assert %Edition{status: "failed"} = Composer.finish(edition.id, {:ok, "again"})
      assert [refund] = ledger(user, "refund")
      assert refund.amount == 3_000
      assert Credits.balance(Accounts.get_user!(user.id)) == 10_000
      assert Books.latest_ready_edition(poet) == nil
    end

    test "an edition left open past its time is settled when next read" do
      {user, poet, _entry} = setup_journey()
      {:ok, edition} = Books.request_composition(user, poet)

      old =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(-31, :minute)
        |> NaiveDateTime.truncate(:second)

      Repo.update_all(from(e in Edition, where: e.id == ^edition.id), set: [inserted_at: old])

      assert %Edition{status: "failed", error: "the composition never finished"} =
               Books.current_edition(poet)

      assert [_refund] = ledger(user, "refund")
    end
  end

  test "the daily run waits while the poet composes its book" do
    {user, poet, _entry} = setup_journey()
    assert DailyJourneyScheduler.eligible(user, poet) == :ok

    {:ok, _} = Books.request_composition(user, poet)

    assert DailyJourneyScheduler.eligible(Accounts.get_user!(user.id), poet) ==
             {:skip, "composing its book"}
  end
end
