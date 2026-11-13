defmodule TravelingPoet.AiCUsersTest do
  # What Alice-in-Context is told so its stairs can say where each reader
  # stands with the app: plain facts per user, a `seen` a day, the visitor
  # counts. AiC works out the stage; nothing here names one.
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.AiCStub, only: [sent: 0, sent: 1]
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Analytics, Credits, Repo, WebPush}
  alias TravelingPoet.AiC.Users

  setup do
    TravelingPoet.AiCStub.start()
  end

  defp facts(user) do
    {_user, attrs} = Enum.find(Users.all(), fn {u, _} -> u.id == user.id end)
    attrs
  end

  test "a reader partway through onboarding: signed in, a step, no channels set up" do
    user = user_fixture(%{onboarding_step: "journey"})
    attrs = facts(user)

    assert attrs["onboarding_step"] == "journey"
    assert attrs["onboarded"] == false
    assert attrs["notifications"] == []
    assert attrs["email_notify"] == true
    assert attrs["paid_cents"] == 0
    assert {:ok, _, _} = DateTime.from_iso8601(attrs["signed_in_at"])
    refute Map.has_key?(attrs, "last_seen_at")
  end

  test "an onboarded reader with Telegram and a browser's pushes; the step is sent empty once done" do
    user =
      user_fixture(%{onboarding_completed: true, onboarding_step: "done", telegram_chat_id: 4242})

    WebPush.subscribe(user, %{
      "endpoint" => "https://push.example/#{user.id}",
      "keys" => %{"p256dh" => "k", "auth" => "a"}
    })

    attrs = facts(user)
    assert attrs["onboarded"] == true
    assert attrs["onboarding_step"] == ""
    assert attrs["notifications"] == ["telegram", "push"]
  end

  test "what a reader paid is the packs they bought, less the ones the store refunded" do
    user = user_fixture()
    {:ok, _} = Credits.purchase(user, "p10", "stripe:cs_a")
    {:ok, _} = Credits.purchase(Accounts.get_user!(user.id), "p50", "stripe:cs_b")
    assert facts(user)["paid_cents"] == 2_500

    {:ok, _} = Credits.reverse_purchase("stripe:cs_a")
    assert facts(user)["paid_cents"] == 2_000
    assert facts(user_fixture())["paid_cents"] == 0
  end

  test "a snapshot goes out once, and again only when a fact changed" do
    user = user_fixture(%{name: "Noa"})
    sent()

    seen = Users.announce(%{})
    events = sent()

    [snap] =
      Enum.filter(
        events,
        &(&1["verb"] == "user_state" and hd(&1["subjects"])["id"] == "user-#{user.id}")
      )

    assert snap["type"] == "state"

    assert hd(snap["subjects"]) == %{
             "kind" => "human",
             "id" => "user-#{user.id}",
             "source" => "traveling-poet",
             "name" => "Noa"
           }

    assert snap["hints"] == %{
             "space" => "organization",
             "address" => "Serve/outer/Users/user-#{user.id}"
           }

    assert snap["metadata"]["attrs"]["onboarded"] == false
    # a name, never the email
    refute Enum.any?(Map.values(snap["metadata"]["attrs"]), &(&1 == user.email))
    assert [_] = Enum.filter(events, &(&1["verb"] == "visitors"))

    assert Users.announce(seen) == seen
    assert sent() == []

    {:ok, _} = Credits.purchase(user, "p10", "stripe:cs_c")
    Users.announce(seen)
    assert [again] = sent("user_state")
    assert again["metadata"]["attrs"]["paid_cents"] == 500
    assert again["id"] != snap["id"]
  end

  test "the app's visitors: today's distinct ones and the week's visitor-days, never people" do
    for v <- ~w(aaaa bbbb), do: Analytics.record(%{visitor: v, name: "pageview", path: "/"})
    Analytics.record(%{visitor: "aaaa", name: "pageview", path: "/about"})

    yesterday = DateTime.add(DateTime.utc_now(:second), -1, :day)
    Analytics.record(%{visitor: "cccc", name: "pageview", path: "/"})

    Repo.update_all(
      from(e in Analytics.VisitEvent, where: e.visitor == "cccc"),
      set: [inserted_at: DateTime.to_naive(yesterday)]
    )

    assert Users.visitors() == {2, 3}

    Users.announce(%{})
    assert [snap] = sent("visitors")
    assert hd(snap["subjects"]) == %{"kind" => "app", "id" => "traveling-poet"}

    assert snap["metadata"]["attrs"] == %{
             "visitors_today" => 2,
             "visitors_7d" => 3,
             "visitors_7d_kind" => "visitor-days"
           }
  end

  test "a reader opening the app says `seen` once a UTC day" do
    user = user_fixture()
    now = ~U[2026-11-13 08:00:00Z]

    user = Accounts.touch_last_seen(user, now)
    assert [seen] = sent("seen")
    assert seen["id"] == "evt_seen_user-#{user.id}_2026-11-13"
    assert seen["actor"]["id"] == "user-#{user.id}"
    assert seen["type"] == "activity"

    user = Accounts.touch_last_seen(user, DateTime.add(now, 3, :hour))
    assert sent("seen") == []

    Accounts.touch_last_seen(user, DateTime.add(now, 1, :day))
    assert [next] = sent("seen")
    assert next["id"] == "evt_seen_user-#{user.id}_2026-11-14"
  end
end
