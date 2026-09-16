defmodule TravelingPoetWeb.BookControllerTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Poets}

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp onboarded_user, do: user_fixture(%{onboarding_completed: true})

  test "a stranger is sent to sign in", %{conn: conn} do
    conn = get(conn, ~p"/journal/book")
    assert redirected_to(conn) =~ "/"
  end

  test "a signed-in user with no poet yet is sent to onboarding", %{conn: conn} do
    user = onboarded_user()
    conn = get(signed_in(conn, user), ~p"/journal/book")
    assert redirected_to(conn) == ~p"/onboarding"
  end

  test "the whole journal, one page a day, in its own layout with no app chrome", %{conn: conn} do
    user = onboarded_user()
    poet = poet_fixture(user, %{name: "Wren"})
    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})

    # 65 published days: past the 60 the journal pages list by default
    for i <- 0..64 do
      published_entry_fixture(poet, %{
        entry_date: Date.add(~D[2026-01-01], i),
        title: "Day number #{i + 1}"
      })
    end

    # and one draft, which is nobody's business yet
    entry_fixture(poet, %{entry_date: ~D[2026-03-07], title: "Still being written"})

    html = conn |> signed_in(user) |> get(~p"/journal/book") |> html_response(200)

    assert html =~ ~s(<body class="book">)
    assert html =~ ~s(src="/assets/js/book.js")
    assert html =~ ~s(href="/assets/css/book.css")
    refute html =~ ~s(href="/assets/css/app.css")
    refute html =~ ~s(src="/assets/js/app.js")
    refute html =~ "navbar"

    assert html =~ ~s(id="book-toc")
    assert html =~ ~s(id="book-index")
    assert html =~ ~s(id="book-print")
    assert html =~ ~s(id="chapter-1")
    assert html =~ "Lisbon, Portugal"

    assert length(Regex.scan(~r/class="book-day"/, html)) == 65
    assert html =~ "Day number 65"
    refute html =~ "Still being written"

    # A5 by default; the size is a whitelisted @page rule
    assert html =~ "@page { size: A5; }"
    assert html =~ ~s(data-size="A5")
  end

  test "?size picks the paper, anything else falls back to A5", %{conn: conn} do
    user = onboarded_user()
    poet_fixture(user)

    html = conn |> signed_in(user) |> get(~p"/journal/book?size=a4") |> html_response(200)
    assert html =~ "@page { size: A4; }"

    html = conn |> signed_in(user) |> get(~p"/journal/book?size=</style>") |> html_response(200)
    assert html =~ "@page { size: A5; }"
    refute html =~ "size: </style>"
  end

  test "drawings, sources and the poet's pick print with their urls and their owner", %{
    conn: conn
  } do
    user = onboarded_user()
    poet = poet_fixture(user, %{name: "Wren"})
    {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
    entry = published_entry_fixture(poet, %{title: "Tram 28"})

    drawing =
      media_fixture(poet, %{
        journal_entry_id: entry.id,
        alt_text: "the tram at dusk",
        sources: %{"items" => [%{"url" => "https://commons.org/tram.jpg", "label" => "the tram"}]}
      })

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{kind: "illustration", media_id: drawing.id},
        %{kind: "description", body: "Rails everywhere. See [the schedule](https://carris.pt)."},
        %{kind: "poem", title: "Bell", body: "one bell\n\ntwo hills"}
      ])

    place_fixture(poet, entry, %{
      name: "Tasca do Chico",
      category: "restaurant",
      address: "Rua do Diario de Noticias 39",
      poet_rating: 4,
      source_url: "https://tasca.pt"
    })

    html = conn |> signed_in(user) |> get(~p"/journal/book") |> html_response(200)

    # the drawing, taped in, naming what it was drawn from
    assert html =~ ~s(src="/media/#{drawing.id}")
    assert html =~ "Drawn from the tram"

    # the day's sources, url written out; the in-prose link stays a link
    assert html =~
             ~s(<a class="book-url" href="https://commons.org/tram.jpg">https://commons.org/tram.jpg</a>)

    assert html =~ ~s(<a class="book-url" href="https://tasca.pt">https://tasca.pt</a>)
    assert html =~ ~s(href="https://carris.pt")

    # the poem has a page of its own
    assert html =~ ~s(class="book-poem")
    assert html =~ "two hills"

    # the gazetteer: address, the poet's OWN pick (never a bare score)
    assert html =~ "Rua do Diario de Noticias 39"
    assert html =~ "★★★★"
    assert html =~ "Wren's pick"

    # the index knows the place, the poem and the journal's own page
    assert html =~ ~s(href="#day-#{entry.entry_date}")
    assert html =~ "Bell"
    assert html =~ "Read online:"
    assert html =~ "/journal/#{entry.entry_date}"
  end

  test "a poet with nothing published yet gets a cover and a note, not an error", %{conn: conn} do
    user = onboarded_user()
    poet_fixture(user, %{name: "Wren"})

    html = conn |> signed_in(user) |> get(~p"/journal/book") |> html_response(200)
    assert html =~ "No pages yet"
    refute html =~ ~s(id="book-index")
  end

  describe "a composed edition" do
    alias TravelingPoet.Books
    alias TravelingPoet.Books.Composer

    setup %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, credits: 10})
      poet = poet_fixture(user, %{name: "Wren"})
      {:ok, _} = Poets.move_to(poet, %{lat: 38.72, lng: -9.13, place_name: "Lisbon, Portugal"})
      entry = published_entry_fixture(poet, %{title: "Tram 28"})

      {:ok, _} =
        Journal.replace_sections(entry, [
          %{kind: "description", body: "Rails everywhere."},
          %{kind: "poem", title: "Bell", body: "one bell rings twice\n\ntwo hills answer"}
        ])

      {:ok, edition} = Books.request_composition(user, poet)
      key = Integer.to_string(Poets.current_path_point(poet.id).id)

      {:ok, _, _} =
        Books.put_matter(poet, %{
          "dedication" => "For Udi, who stayed home",
          "foreword" => "I set out to find the hills.",
          "epilogue" => "The hills stayed with me.",
          "chapter_openers" => %{key => "Lisbon took me in first."},
          "pull_quotes" => [
            %{"entry_date" => Date.to_iso8601(entry.entry_date), "text" => "two hills answer"}
          ]
        })

      Composer.finish(edition.id, {:ok, "done"})

      %{conn: signed_in(conn, user), poet: poet, entry: entry}
    end

    test "binds the poet's words around the journal", %{conn: conn} do
      html = conn |> get(~p"/journal/book") |> html_response(200)

      assert html =~ ~s(id="book-dedication")
      assert html =~ "For Udi, who stayed home"
      assert html =~ ~s(id="book-foreword")
      assert html =~ "I set out to find the hills."
      assert html =~ "Lisbon took me in first."
      assert html =~ ~s(class="book-pull-quote")
      assert html =~ "two hills answer"
      assert html =~ ~s(id="book-epilogue")
      assert html =~ ~s(href="#book-foreword")
      assert html =~ "composed by Wren for this edition"
      assert html =~ ~s(id="edition-plain")
    end

    test "?edition=plain prints the journal as written", %{conn: conn} do
      html = conn |> get(~p"/journal/book?edition=plain") |> html_response(200)

      refute html =~ ~s(id="book-dedication")
      refute html =~ "Lisbon took me in first."
      refute html =~ ~s(class="book-pull-quote")
      assert html =~ "two hills answer"

      assert html =~
               ~r/id="edition-plain"[^>]*class="active"|class="active"[^>]*id="edition-plain"/s
    end

    test "a quote whose line was since revised away is not printed", %{conn: conn, entry: entry} do
      {:ok, _} =
        Journal.replace_sections(entry, [%{kind: "poem", title: "Bell", body: "one bell only"}])

      html = conn |> get(~p"/journal/book") |> html_response(200)
      refute html =~ ~s(class="book-pull-quote")
      assert html =~ "For Udi, who stayed home"
    end
  end
end
