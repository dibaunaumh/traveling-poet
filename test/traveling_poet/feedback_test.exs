defmodule TravelingPoet.FeedbackTest do
  @moduledoc "What readers tell us about the app (card-137): messages, the recommend question, and paging the admins."
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Accounts.Purge
  alias TravelingPoet.Feedback
  alias TravelingPoet.Feedback.{Message, NpsResponse}
  alias TravelingPoet.Telegram.Notifier

  setup do
    Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "admin_events")
    :ok
  end

  describe "messages" do
    test "a reader's message is stored as theirs and pages the admins" do
      user = user_fixture()

      assert {:ok, %Message{id: id} = message} =
               Feedback.create_message(user, %{
                 "kind" => "broken",
                 "body" => "  The map is blank  ",
                 "email" => "ignored@example.com",
                 "page" => "/guide"
               })

      assert message.user_id == user.id
      assert message.email == nil
      assert message.body == "The map is blank"
      assert message.status == "new"
      assert_receive {:feedback_received, ^id}
    end

    test "a visitor must leave an email address" do
      assert {:error, changeset} =
               Feedback.create_message(nil, %{"kind" => "missing", "body" => "Dark mode"})

      assert %{email: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               Feedback.create_message(nil, %{
                 "kind" => "missing",
                 "body" => "Dark mode",
                 "email" => "not an address"
               })

      assert %{email: [_]} = errors_on(changeset)

      assert {:ok, message} =
               Feedback.create_message(nil, %{
                 "kind" => "missing",
                 "body" => "Dark mode",
                 "email" => " Wren@Example.com "
               })

      assert message.user_id == nil
      assert message.email == "wren@example.com"
    end

    test "kind and body are required, and the kind is one of four" do
      assert {:error, changeset} = Feedback.create_message(user_fixture(), %{"kind" => "rant"})
      assert %{kind: [_], body: ["can't be blank"]} = errors_on(changeset)
      refute_receive {:feedback_received, _}
    end

    test "five a day per sender, then a polite no" do
      user = user_fixture()

      for n <- 1..Feedback.daily_cap() do
        assert {:ok, _} = Feedback.create_message(user, %{"kind" => "other", "body" => "#{n}"})
      end

      assert {:error, :too_many} =
               Feedback.create_message(user, %{"kind" => "other", "body" => "6"})

      # Someone else is not held back by it
      assert {:ok, _} =
               Feedback.create_message(user_fixture(), %{"kind" => "other", "body" => "1"})
    end

    test "listing new ones, and marking one done" do
      user = user_fixture()
      {:ok, a} = Feedback.create_message(user, %{"kind" => "broken", "body" => "a"})
      {:ok, b} = Feedback.create_message(user, %{"kind" => "change", "body" => "b"})

      {:ok, _} = Feedback.set_status(a, "done")
      assert [%{id: id}] = Feedback.list_messages(status: "new")
      assert id == b.id
      assert length(Feedback.list_messages()) == 2
    end

    test "deleting an account takes the notes it sent signed out from its address" do
      user = user_fixture(%{email: "wren@example.com"})
      {:ok, _} = Feedback.create_message(user, %{"kind" => "broken", "body" => "signed in"})

      {:ok, _} =
        Feedback.create_message(nil, %{
          "kind" => "broken",
          "body" => "signed out",
          "email" => "wren@example.com"
        })

      {:ok, kept} =
        Feedback.create_message(nil, %{
          "kind" => "broken",
          "body" => "someone else",
          "email" => "other@example.com"
        })

      assert {:ok, _} = Purge.purge(user.id, "wren@example.com")
      assert [%{id: id}] = Feedback.list_messages()
      assert id == kept.id
    end
  end

  describe "the recommend question" do
    test "a score is kept at once; the words after it page the admins, once" do
      user = user_fixture()

      assert {:ok, %NpsResponse{id: id, score: 6} = response} = Feedback.record_score(user, 6)
      refute_receive {:nps_answered, _}

      assert {:ok, %{comment: "More maps"}} = Feedback.finish_response(response, " More maps ")
      assert_receive {:nps_answered, ^id}
    end

    test "skipping the words still pages the admins" do
      {:ok, %{id: id} = response} = Feedback.record_score(user_fixture(), 10)
      assert {:ok, %{comment: nil}} = Feedback.finish_response(response, nil)
      assert_receive {:nps_answered, ^id}
    end

    test "a score is 0 to 10" do
      assert {:error, _} = Feedback.record_score(user_fixture(), 11)
      assert {:error, _} = Feedback.record_score(user_fixture(), -1)
    end

    test "due from day 7, not again after an answer, resting after Not now" do
      user = user_fixture()
      refute Feedback.nps_due?(user, 6)
      assert Feedback.nps_due?(user, 7)

      {:ok, _} = Feedback.record_score(user, 8)
      refute Feedback.nps_due?(user, 30)

      other = user_fixture()
      {:ok, other} = Feedback.dismiss_nps(other)
      refute Feedback.nps_due?(other, 30)
    end

    test "the summary counts each reader's latest answer" do
      a = user_fixture()
      b = user_fixture()
      c = user_fixture()
      {:ok, _} = Feedback.record_score(a, 3)
      {:ok, _} = Feedback.record_score(a, 9)
      {:ok, _} = Feedback.record_score(b, 10)
      {:ok, _} = Feedback.record_score(c, 7)

      assert %{count: 3, promoters: 2, passives: 1, detractors: 0, score: 67} =
               Feedback.nps_summary(90)
    end

    test "the score is percent promoters minus percent detractors" do
      assert %{score: nil, count: 0} = Feedback.summarize([])
      assert %{score: 0} = Feedback.summarize([10, 0])
      assert %{score: -50, detractors: 3, promoters: 1} = Feedback.summarize([0, 5, 6, 9])
    end
  end

  describe "what the admins read on Telegram" do
    test "a reader's message" do
      user = %{name: "Wren", email: "wren@example.com"}

      text =
        Notifier.feedback_alert_text(
          %Message{
            kind: "broken",
            body: "The map is blank",
            page: "/guide",
            client: "iOS app",
            user: user
          },
          %{name: "Ada"}
        )

      assert text =~
               "Something is broken, from Wren <wren@example.com>, poet Ada (/guide, iOS app):"

      assert text =~ "\n\nThe map is blank\n\n"
      assert text =~ "/admin/feedback"
    end

    test "a visitor's message, cut when long" do
      text =
        Notifier.feedback_alert_text(
          %Message{
            kind: "missing",
            body: String.duplicate("a", 700),
            email: "v@example.com",
            user: nil
          },
          nil
        )

      assert text =~ "Something is missing, from v@example.com (signed out):"
      assert text =~ String.duplicate("a", 600) <> "…"
      refute text =~ String.duplicate("a", 601)
    end

    test "an answer to the recommend question" do
      user = %{name: "Wren", email: "wren@example.com"}

      assert Notifier.nps_alert_text(
               %NpsResponse{score: 6, comment: "More maps", user: user},
               nil
             ) =~
               "Recommend score 6/10 (detractor) from Wren <wren@example.com>:\n\nMore maps"

      assert Notifier.nps_alert_text(%NpsResponse{score: 10, user: user}, %{name: "Ada"}) =~
               "Recommend score 10/10 (promoter) from Wren <wren@example.com>, poet Ada, no comment."
    end
  end
end
