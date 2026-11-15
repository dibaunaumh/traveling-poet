defmodule TravelingPoetWeb.QuizLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Journal, Quizzes, Repo}
  alias TravelingPoet.Quizzes.Answer

  @today Date.utc_today()

  # Four earlier pages, then today's quiz page with one question of each kind.
  defp quiz_day(conn) do
    user = agent_user_fixture(%{onboarding_completed: true, sprite_url: nil})
    poet = poet_fixture(user, %{is_public: true})

    pages =
      for i <- 1..4 do
        entry =
          published_entry_fixture(poet, %{
            entry_date: Date.add(@today, -(5 - i)),
            place_name: "Town #{i}, Portugal"
          })

        drawing = media_fixture(poet, %{journal_entry_id: entry.id})

        {:ok, _} =
          Journal.replace_sections(entry, [
            %{
              "kind" => "description",
              "body" =>
                "In Town #{i} the bell-ringer keeps #{i} bees in the tower, and nobody minds them.\n\n" <>
                  "The bakery on the square in Town #{i} only bakes its bread when the tide is out."
            },
            %{"kind" => "illustration", "media_id" => drawing.id}
          ])

        {entry, drawing}
      end

    key = fn {entry, _}, nth ->
      entry = Journal.preload_entry(entry)
      Enum.at(Journal.Paragraphs.of_sections(entry.sections), nth).key
    end

    [p1, p2, p3, p4] = pages
    {_, d1} = p1

    {:ok, _} = Quizzes.hold_day(poet, @today)
    entry = entry_fixture(poet, %{entry_date: @today, title: "What stayed with you?"})

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{"kind" => "description", "body" => "No train today. Let's see what you remember."}
      ])

    {:ok, _} =
      Quizzes.put(poet, entry, %{
        "notes" => %{
          "high" => "You were with me the whole way.",
          "mid" => "Most of the road stayed with you.",
          "low" => "That is why I write it all down."
        },
        "questions" => [
          %{
            "kind" => "choice",
            "prompt" => "How many bees in the tower of Town 2?",
            "options" => ["Two", "Twelve", "None"],
            "answer" => "a",
            "source_key" => key.(p2, 0),
            "aside" => "He named every one."
          },
          %{
            "kind" => "fib",
            "prompt" => "Two truths and a fib.",
            "options" => [
              %{"text" => "Bees in the tower of Town 3", "source_key" => key.(p3, 0)},
              %{"text" => "A baker who waits for the tide", "source_key" => key.(p4, 1)},
              %{"text" => "A mayor who rides a camel"}
            ],
            "answer" => "c"
          },
          %{
            "kind" => "drawing",
            "prompt" => "Where did I draw this?",
            "media_id" => d1.id,
            "options" => ["Town 3", "Town 1", "Town 4"],
            "answer" => "b"
          },
          %{
            "kind" => "first",
            "prompt" => "Which came first?",
            "options" => [
              %{"text" => "The tide bakery of Town 4", "source_key" => key.(p4, 1)},
              %{"text" => "The bees of Town 1", "source_key" => key.(p1, 0)},
              %{"text" => "The bees of Town 3", "source_key" => key.(p3, 0)}
            ]
          }
        ]
      })

    {:ok, entry} = Journal.publish_entry(Repo.reload!(entry))
    quiz = Quizzes.playable(entry)
    {conn, user, poet, entry, quiz}
  end

  defp answer(view, question, option) do
    view
    |> element("#quiz-q-#{question.id}-#{option}")
    |> render_click()
  end

  defp next(view), do: view |> element(".quiz-next") |> render_click()

  test "the owner plays one question at a time, and the answers are kept", %{conn: conn} do
    {conn, user, _poet, _entry, quiz} = quiz_day(conn)
    conn = Plug.Test.init_test_session(conn, %{user_id: user.id})
    [q1, q2, q3, q4] = quiz.questions

    {:ok, view, html} = live(conn, ~p"/journal")
    assert has_element?(view, "#quiz-q-#{q1.id}")
    # nothing on the page says which answer is right before they answer
    refute html =~ "is-right"
    # a quiz page has no Places tab
    refute has_element?(view, "a", "Places")

    html = answer(view, q1, "b")
    assert html =~ "Not quite. It was A."
    assert html =~ "He named every one."
    assert has_element?(view, "#quiz-q-#{q1.id}-a.is-right")
    assert has_element?(view, "#quiz-q-#{q1.id}-b.is-wrong")
    next(view)

    answer(view, q2, "c")
    assert has_element?(view, ".quiz-stamp.is-new")
    next(view)
    answer(view, q3, "b")
    next(view)
    # which came first: the app knew it was Town 1
    answer(view, q4, "b")
    html = next(view)

    assert html =~ "3 of 4"
    assert html =~ "Fellow traveler"
    assert html =~ "Most of the road stayed with you."
    assert Repo.aggregate(Answer, :count) == 4

    # back later: the score is still there, and a second try changes nothing
    {:ok, _view, html} = live(conn, ~p"/journal")
    assert html =~ "3 of 4"
    assert {:ok, _} = Quizzes.answer(quiz, user, q1.id, "a")
    assert Quizzes.score(quiz, Quizzes.answers_for(quiz, user.id)).right == 3
  end

  test "a visitor plays the public page and nothing of theirs is kept", %{conn: conn} do
    {conn, _user, poet, entry, quiz} = quiz_day(conn)

    {:ok, view, _html} = live(conn, ~p"/p/#{poet.slug}/#{Date.to_iso8601(entry.entry_date)}")
    assert render(view) =~ "Play along. Your answers are not saved."

    for {question, option} <- Enum.zip(quiz.questions, ~w(a c b b)) do
      answer(view, question, option)
      next(view)
    end

    html = render(view)
    assert html =~ "4 of 4"
    assert html =~ "Bravo!"
    assert html =~ "You were with me the whole way."
    assert Repo.aggregate(Answer, :count) == 0
  end
end
