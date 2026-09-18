defmodule TravelingPoet.AnalyticsTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Analytics
  alias TravelingPoet.Analytics.VisitEvent
  alias TravelingPoet.Repo

  @ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15"

  defp since, do: DateTime.utc_now() |> DateTime.add(-1, :day)

  defp event(visitor, name, attrs \\ %{}) do
    :ok = Analytics.record(Map.merge(%{visitor: visitor, name: name, path: "/"}, attrs))
  end

  describe "visitor_id/3" do
    test "is stable within a day and changes with the day, the IP or the browser" do
      today = ~D[2026-09-18]
      id = Analytics.visitor_id("1.2.3.4", @ua, today)

      assert id == Analytics.visitor_id("1.2.3.4", @ua, today)
      assert byte_size(id) == 16
      refute id == Analytics.visitor_id("1.2.3.4", @ua, ~D[2026-09-19])
      refute id == Analytics.visitor_id("1.2.3.5", @ua, today)
      refute id == Analytics.visitor_id("1.2.3.4", "Firefox", today)
    end

    test "prefers Fly's client IP header over the socket peer" do
      conn = Plug.Test.conn(:get, "/") |> Plug.Conn.put_req_header("fly-client-ip", "9.9.9.9")
      assert Analytics.client_ip(conn) == "9.9.9.9"
      assert Analytics.client_ip(Plug.Test.conn(:get, "/")) == "127.0.0.1"
    end
  end

  test "bot?/1 catches crawlers, unfurlers and empty agents, not browsers" do
    assert Analytics.bot?("Googlebot/2.1")
    assert Analytics.bot?("WhatsApp/2.23")
    assert Analytics.bot?("Mozilla/5.0 HeadlessChrome/120")
    assert Analytics.bot?("")
    assert Analytics.bot?(nil)
    refute Analytics.bot?(@ua)
  end

  describe "record/1" do
    test "stores an event, truncating long strings" do
      assert :ok =
               Analytics.record(%{
                 visitor: "v1",
                 name: "click",
                 target: String.duplicate("x", 500)
               })

      assert [%VisitEvent{target: target}] = Repo.all(VisitEvent)
      assert String.length(target) == 60
    end

    test "drops unknown names and out-of-range numbers without raising" do
      assert :dropped = Analytics.record(%{visitor: "v1", name: "purchase"})
      assert :dropped = Analytics.record(%{visitor: "v1", name: "engage", scroll_pct: 400})
      assert :dropped = Analytics.record(%{name: "pageview"})
      assert Repo.aggregate(VisitEvent, :count) == 0
    end

    test "caps one visitor's events per minute" do
      results = for _ <- 1..61, do: Analytics.record(%{visitor: "flood", name: "click"})
      assert Enum.count(results, &(&1 == :ok)) == 60
      assert List.last(results) == :dropped
      assert :ok = Analytics.record(%{visitor: "someone-else", name: "click"})
    end
  end

  test "prune/1 deletes only events older than the retention window" do
    event("old", "pageview")
    event("new", "pageview")
    old = DateTime.utc_now() |> DateTime.add(-200, :day) |> DateTime.truncate(:second)
    Repo.update_all(from(e in VisitEvent, where: e.visitor == "old"), set: [inserted_at: old])

    assert Analytics.prune() == 1
    assert [%{visitor: "new"}] = Repo.all(VisitEvent)
  end

  describe "funnel/1" do
    test "counts visitors down to sign-up, onboarding and a first entry" do
      # three visitors: one bounces, one reads, one reads and clicks start
      event("a", "pageview")
      event("a", "engage", %{duration_ms: 2_000, scroll_pct: 5})
      event("b", "pageview")
      event("b", "engage", %{duration_ms: 40_000, scroll_pct: 80})
      event("c", "pageview")
      event("c", "click", %{target: "cta-hero-place"})
      event("c", "click", %{target: "how-it-works"})

      stuck = user_fixture(%{onboarding_step: "journey"})
      done = user_fixture(%{onboarding_step: "done", onboarding_completed: true})
      poet = poet_fixture(done)
      published_entry_fixture(poet)

      counts = Map.new(Analytics.funnel(since()))

      assert counts["Visited any page"] == 3
      assert counts["Stayed 10s, scrolled half a page, or clicked"] == 2
      assert counts["Clicked a start or sign-in button"] == 1
      assert counts["Signed up"] == 2
      assert counts["Onboarding: picked a poet"] == 2
      assert counts["Onboarding: set the journey"] == 2
      assert counts["Onboarding: reached send-off"] == 1
      assert counts["Onboarding: finished"] == 1
      assert counts["First entry published"] == 1

      assert [%{email: email, step: "journey"}] = Analytics.stuck_in_onboarding(since())
      assert email == stuck.email
    end

    test "pages/1 reports bounces and the median of each visitor's longest stay" do
      event("a", "pageview")
      event("a", "engage", %{duration_ms: 3_000})
      event("b", "pageview")
      event("b", "engage", %{duration_ms: 20_000})
      # b came back to the tab: a second, larger running total
      event("b", "engage", %{duration_ms: 50_000})
      event("c", "pageview")
      event("c", "engage", %{duration_ms: 60_000})

      assert [%{path: "/", visitors: 3, bounce_pct: 33, median_s: 50}] = Analytics.pages(since())
    end
  end
end
