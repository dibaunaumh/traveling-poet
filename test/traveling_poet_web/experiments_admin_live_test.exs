defmodule TravelingPoetWeb.ExperimentsAdminLiveTest do
  @moduledoc "Blind writing tests judged in the admin pages, votes kept on the server."
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Evals.BlindTests

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp page(title, body) do
    %{
      "title" => title,
      "teaser" => "",
      "sections" => [%{"kind" => "description", "title" => "", "body" => body}]
    }
  end

  defp result(day, cid, page),
    do: %{
      "day_id" => day,
      "candidate_id" => cid,
      "status" => "ok",
      "page" => page,
      "metrics" => %{"words" => 3, "disclaimers" => 0, "mixed_words" => 0, "foreign_chars" => 0}
    }

  defp manifest do
    %{
      "run_id" => "shadow-test",
      "candidates" => [
        %{"id" => "published", "model" => "sprite (OpenClaw)"},
        %{"id" => "app-loop", "model" => "app loop (shadow)"}
      ],
      "days" => [
        %{
          "id" => "1-2026-11-20",
          "poet" => "Nam",
          "language" => "en",
          "entry_date" => "2026-11-20"
        },
        %{
          "id" => "1-2026-11-21",
          "poet" => "Nam",
          "language" => "en",
          "entry_date" => "2026-11-21"
        }
      ],
      "results" => [
        result("1-2026-11-20", "published", page("Sprite one", "The sprite wrote this.")),
        result("1-2026-11-20", "app-loop", page("Loop one", "The loop wrote this.")),
        result("1-2026-11-21", "published", page("Sprite two", "Again the sprite.")),
        result("1-2026-11-21", "app-loop", page("Loop two", "Again the loop."))
      ],
      "blind" => %{
        "1-2026-11-20" => %{"A" => "app-loop", "B" => "published"},
        "1-2026-11-21" => %{"A" => "published", "B" => "app-loop"}
      }
    }
  end

  setup do
    {:ok, test} = BlindTests.import_manifest(manifest(), "Shadow week")
    %{blind: test, admin: user_fixture(%{is_admin: true})}
  end

  test "the judge votes day by day, every tap kept on the server, then reveals", %{
    conn: conn,
    admin: admin
  } do
    {:ok, view, html} = live(sign_in(conn, admin), ~p"/admin/experiments/shadow-test")
    assert html =~ "Loop one"
    # an English day reads left to right; a Hebrew one right to left
    assert has_element?(view, ~s(#page-A [dir="ltr"]))
    assert html =~ "Sprite one"
    # only letters, never who wrote it
    refute html =~ "app-loop"
    refute html =~ "OpenClaw"

    view |> element("#best-A") |> render_click()
    view |> element("#mark-publishable-B") |> render_click()
    view |> element("#mark-publishable-A") |> render_click()

    assert BlindTests.get("shadow-test").votes == %{
             "1-2026-11-20" => %{
               "best" => "A",
               "publishable" => ["A", "B"],
               "gibberish" => [],
               "preachy" => []
             }
           }

    refute has_element?(view, "#reveal-button")

    view |> element("#next-day") |> render_click()
    assert render(view) =~ "Sprite two"
    view |> element("#best-B") |> render_click()

    # the votes outlive the page
    {:ok, view, _} = live(sign_in(build_conn(), admin), ~p"/admin/experiments/shadow-test?day=2")
    assert has_element?(view, "#best-B.btn-primary")

    view |> element("#reveal-button") |> render_click()
    table = view |> element("#reveal-table") |> render()
    assert table =~ "app loop (shadow)"

    rows = Map.new(BlindTests.tally(BlindTests.get("shadow-test")), &{&1.id, &1})
    assert rows["app-loop"].wins == 2
    assert rows["published"].wins == 0
    assert rows["app-loop"].publishable == 1
    assert rows["published"].publishable == 1
  end

  test "a Hebrew day's pages read right to left", %{conn: conn, admin: admin} do
    m = manifest()

    m = %{
      m
      | "run_id" => "he-test",
        "days" => Enum.map(m["days"], &Map.put(&1, "language", "he"))
    }

    {:ok, _} = BlindTests.import_manifest(m)
    {:ok, view, _} = live(sign_in(conn, admin), ~p"/admin/experiments/he-test")
    assert has_element?(view, ~s(#page-A [dir="rtl"]))
  end

  test "picking the best page again clears it, and a letter not on the day is refused", %{
    blind: test
  } do
    {:ok, test} = BlindTests.set_best(test, "1-2026-11-20", "A")
    {:ok, test} = BlindTests.set_best(test, "1-2026-11-20", "A")
    assert BlindTests.vote(test, "1-2026-11-20")["best"] == nil
    assert {:error, :unknown_page} = BlindTests.set_best(test, "1-2026-11-20", "C")
    assert {:error, :unknown_mark} = BlindTests.toggle_mark(test, "1-2026-11-20", "A", "rude")
  end

  test "reloading a manifest keeps the votes", %{blind: test} do
    {:ok, _} = BlindTests.set_best(test, "1-2026-11-20", "B")
    {:ok, reloaded} = BlindTests.import_manifest(manifest())
    assert BlindTests.judged(reloaded) == 1
  end

  test "the list shows each test's progress, for admins only", %{conn: conn, admin: admin} do
    {:ok, _view, html} = live(sign_in(conn, admin), ~p"/admin/experiments")
    assert html =~ "Shadow week"
    assert html =~ "0 of 2 days judged"

    assert {:error, {:redirect, %{to: "/"}}} =
             live(sign_in(build_conn(), user_fixture()), ~p"/admin/experiments/shadow-test")
  end
end
