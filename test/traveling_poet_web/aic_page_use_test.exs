defmodule TravelingPoetWeb.AiCPageUseTest do
  # What Alice-in-Context hears of a page in use: that a notification's link
  # was followed, how long its owner spent on each part, what they pressed,
  # and the page again when the poet adds to it after publishing. A public
  # reader is never measured.
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.AiCStub, only: [sent: 0, sent: 1]
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Journal}
  alias TravelingPoet.Journal.Paragraphs

  @para "Lisbon hits you first by smell: salt, diesel, baking bread, and something floral."

  setup do
    TravelingPoet.AiCStub.start()

    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{is_public: true})
    date = Date.utc_today()

    {:ok, entry} =
      Journal.upsert_entry(poet.id, date, %{title: "The rooftop", place_name: "Lisbon"})

    {:ok, _} = Journal.replace_sections(entry, [%{kind: "description", body: @para}])
    {:ok, entry} = Journal.publish_entry(entry)
    place = place_fixture(poet, entry)
    sent()

    %{user: user, poet: poet, entry: entry, place: place, date: Date.to_iso8601(date)}
  end

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp part_reads, do: sent("read") |> Enum.filter(& &1["metadata"]["part"])

  test "a page opened from a notification's link says which notification was read",
       %{conn: conn, user: user, entry: entry, date: date} do
    {:ok, _view, _html} = live(sign_in(conn, user), ~p"/journal/#{date}?via=email")

    reads = sent("read")
    assert [via] = Enum.filter(reads, &(&1["metadata"]["via"] == "email"))
    assert via["id"] =~ "_via-email"
    assert via["actor"]["id"] == "user-#{user.id}"
    assert via["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
    # the plain read of the page is still there, a different event
    assert Enum.any?(reads, &(&1["metadata"] == %{"channel" => "owner"}))

    {:ok, _view, _html} = live(sign_in(conn, user), ~p"/journal/#{date}?via=carrier-pigeon")
    refute Enum.any?(sent("read"), & &1["metadata"]["via"])
  end

  test "the time the hook reports is told by part of the page",
       %{conn: conn, user: user, entry: entry, date: date} do
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/journal/#{date}")

    render_hook(view, "paragraph_reads", %{
      "entry_id" => to_string(entry.id),
      "reads" => %{Paragraphs.key(@para) => 6_000}
    })

    assert [read] = part_reads()
    assert read["metadata"] == %{"channel" => "owner", "part" => "story"}
    assert read["metrics"] == %{"seconds" => 6}
    assert read["actor"]["id"] == "user-#{user.id}"
  end

  test "turning to the places is a read of that part, with a mount for link clicks",
       %{conn: conn, user: user, entry: entry, date: date} do
    {:ok, view, html} = live(sign_in(conn, user), ~p"/journal/#{date}?spread=places")
    assert html =~ ~s(phx-hook="LinkClicks")
    assert html =~ ~s(id="links-#{entry.id}")

    assert [read] = part_reads()
    assert read["metadata"]["part"] == "places"
    assert read["metrics"]["seconds"] >= 0

    render_hook(view, "link_click", %{
      "entry_id" => to_string(entry.id),
      "spread" => "places",
      "host" => "example.com"
    })

    assert [click] = sent("interact")
    assert click["body"] == %{"text" => "link"}
    assert click["metadata"] == %{"action" => "link", "part" => "places", "host" => "example.com"}

    # a click reported for another page is not this page's
    render_hook(view, "link_click", %{"entry_id" => "0", "host" => "example.com"})
    assert sent("interact") == []
  end

  test "a place saved is told once; taking it back is not",
       %{conn: conn, user: user, poet: poet, entry: entry, place: place, date: date} do
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/journal/#{date}?spread=places")

    render_hook(view, "toggle_bookmark", %{"kind" => "place", "id" => place.id})

    assert [saved] = sent("interact")
    assert saved["actor"]["id"] == "user-#{user.id}"
    assert saved["recipient"]["id"] == "poet-#{poet.id}"
    assert saved["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
    assert saved["metadata"] == %{"action" => "saved", "part" => "places"}

    render_hook(view, "toggle_bookmark", %{"kind" => "place", "id" => place.id})
    assert sent("interact") == []

    render_hook(view, "toggle_pass", %{"kind" => "place", "id" => place.id})
    assert [passed] = sent("interact")
    assert passed["metadata"] == %{"action" => "not for me", "part" => "places"}
  end

  test "a reaction given is feedback on the page; one taken back is not",
       %{conn: conn, user: user, entry: entry, date: date} do
    {:ok, view, _html} = live(sign_in(conn, user), ~p"/journal/#{date}")

    render_hook(view, "react", %{"kind" => "not_for_me"})
    assert [ev] = sent("reaction")
    assert ev["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
    assert ev["metadata"] == %{"kind" => "not_for_me", "sentiment" => "negative"}

    render_hook(view, "react", %{"kind" => "not_for_me"})
    assert sent("reaction") == []
  end

  test "with reading signals off no part is timed and no link is followed",
       %{conn: conn, user: user, entry: entry, date: date} do
    {:ok, user} = Accounts.update_user(user, %{reading_signals: false})
    {:ok, view, html} = live(sign_in(conn, user), ~p"/journal/#{date}?spread=places")
    refute html =~ "LinkClicks"

    render_hook(view, "paragraph_reads", %{
      "entry_id" => to_string(entry.id),
      "reads" => %{Paragraphs.key(@para) => 6_000}
    })

    render_hook(view, "link_click", %{"entry_id" => to_string(entry.id), "host" => "example.com"})

    events = sent()
    assert Enum.filter(events, & &1["metadata"]["part"]) == []
    assert Enum.filter(events, &(&1["verb"] == "interact")) == []
    # the page itself was still opened
    assert Enum.any?(events, &(&1["verb"] == "read"))
  end

  test "a public reader is never measured, whatever the link says",
       %{conn: conn, user: owner, poet: poet, date: date} do
    reader = user_fixture()
    {:ok, _view, html} = live(sign_in(conn, reader), ~p"/p/#{poet.slug}/#{date}?via=email")
    refute html =~ "LinkClicks"

    reads = sent("read")
    assert [read] = reads
    assert read["metadata"] == %{"channel" => "public"}

    # the owner, reading their own public page from a push
    {:ok, _view, _html} = live(sign_in(conn, owner), ~p"/p/#{poet.slug}/#{date}?via=push")
    assert Enum.any?(sent("read"), &(&1["metadata"]["via"] == "push"))
  end

  test "places the poet adds after publishing correct the page that was reported",
       %{conn: conn, user: user, entry: entry, date: date} do
    TravelingPoet.AiC.journal_published(entry)
    [first] = sent("journal_published")
    assert %{"id" => "places", "count" => 1} in first["metadata"]["page"]["parts"]

    conn
    |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
    |> put_req_header("content-type", "application/json")
    |> put(~p"/api/agent/journal_entries/#{date}/places", %{
      "places" => [
        %{"name" => "Cafe A Brasileira", "category" => "cafe"},
        %{"name" => "Miradouro da Graca", "category" => "viewpoint"}
      ]
    })
    |> json_response(200)

    assert [again] = sent("journal_published")
    assert again["id"] != first["id"]
    assert again["subjects"] == [%{"kind" => "entry", "id" => to_string(entry.id)}]
    assert %{"id" => "places", "count" => 2} in again["metadata"]["page"]["parts"]
  end
end
