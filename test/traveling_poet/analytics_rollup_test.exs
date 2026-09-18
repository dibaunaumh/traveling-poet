defmodule TravelingPoet.Analytics.RollupTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Analytics
  alias TravelingPoet.Analytics.{FunnelDay, Rollup, VisitEvent}
  alias TravelingPoet.ChangeStream.{Capture, Event}
  alias TravelingPoet.Repo

  @today ~D[2026-09-18]

  defp at(date), do: DateTime.new!(date, ~T[12:00:00], "Etc/UTC")

  defp event(visitor, name, attrs \\ %{}, date \\ @today) do
    :ok = Analytics.record(Map.merge(%{visitor: visitor, name: name, path: "/"}, attrs))

    {1, _} =
      Repo.update_all(
        from(e in VisitEvent, where: e.id == ^Repo.one(from e in VisitEvent, select: max(e.id))),
        set: [inserted_at: at(date)]
      )
  end

  defp signed_up(visitor, attrs) do
    user = user_fixture(attrs)
    naive = @today |> at() |> DateTime.to_naive()

    Repo.update_all(from(u in TravelingPoet.Accounts.User, where: u.id == ^user.id),
      set: [inserted_at: naive]
    )

    event(visitor, "signup", %{user_id: user.id})
    user
  end

  defp row(source, day \\ @today), do: Repo.get_by!(FunnelDay, day: day, source: source)

  test "builds an all-traffic row and one per source, with visit and account steps" do
    # a: from the newsletter, reads, clicks start, signs up, finishes onboarding
    event("a", "pageview", %{utm_source: "newsletter"})
    event("a", "engage", %{duration_ms: 30_000, scroll_pct: 80})
    event("a", "click", %{target: "cta-hero-place"})
    done = signed_up("a", %{onboarding_step: "done", onboarding_completed: true})
    published_entry_fixture(poet_fixture(done))

    # b: from the newsletter, bounces
    event("b", "pageview", %{utm_source: "newsletter"})
    event("b", "engage", %{duration_ms: 2_000, scroll_pct: 5})

    # c: direct, signs up, stops at the journey step
    event("c", "pageview")
    event("c", "engage", %{duration_ms: 12_000})
    signed_up("c", %{onboarding_step: "journey"})

    Rollup.run(3, @today)

    all = row("all")
    assert {all.visitors, all.engaged, all.cta_visitors, all.bounced} == {3, 2, 1, 1}
    assert all.median_visible_s == 12

    assert {all.signups, all.onboarding_journey, all.onboarding_done, all.first_entries} ==
             {2, 2, 1, 1}

    news = row("newsletter")
    assert {news.visitors, news.engaged, news.cta_visitors, news.bounced} == {2, 1, 1, 1}
    assert {news.signups, news.onboarding_done, news.first_entries} == {1, 1, 1}

    # empty days in the window still get an all row, so a day with no visitors reads as 0
    assert row("all", Date.add(@today, -1)).visitors == 0
    assert Repo.aggregate(FunnelDay, :count) == 4
  end

  test "rewrites a row only when its numbers change, so the change stream stays quiet" do
    event("a", "pageview")
    Rollup.run(1, @today)
    Capture.tick()
    assert [%{entity: "funnel_days", action: "insert"}] = Repo.all(Event)

    assert %{written: 0} = Rollup.run(1, @today)
    assert %{inserts: 0, updates: 0, deletes: 0} = Capture.tick()

    event("b", "pageview")
    assert %{written: 1} = Rollup.run(1, @today)
    assert %{updates: 1} = Capture.tick()

    [_, update] = Repo.all(from e in Event, order_by: e.id)
    assert update.payload["visitors"] == 2
    refute Map.has_key?(update.payload, "visitor")
  end

  test "drops a source row that no longer applies" do
    event("a", "pageview", %{utm_source: "x"})
    Rollup.run(1, @today)
    assert row("x").visitors == 1

    Repo.delete_all(VisitEvent)
    assert %{deleted: 1} = Rollup.run(1, @today)
    assert Repo.get_by(FunnelDay, source: "x") == nil
  end
end
