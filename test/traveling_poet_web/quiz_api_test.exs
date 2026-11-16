defmodule TravelingPoetWeb.QuizApiTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Credits, DailyJourneyScheduler, Journal, Poets, Quizzes, Repo}
  alias TravelingPoet.Quizzes.{Answer, Question}
  alias TravelingPoet.Reading.ParagraphRead

  setup %{conn: conn} do
    previous = Application.get_env(:traveling_poet, :quiz_enabled)
    Application.put_env(:traveling_poet, :quiz_enabled, "all")
    on_exit(fn -> Application.put_env(:traveling_poet, :quiz_enabled, previous) end)

    user = agent_user_fixture()
    # arrived yesterday: today is a plain stay day, not the arrival
    yesterday = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
    poet = poet_fixture(user, %{stay_duration_days: 3, arrived_at: yesterday})

    authed =
      conn
      |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
      |> put_req_header("content-type", "application/json")

    %{conn: authed, user: user, poet: poet}
  end

  @today Date.utc_today()

  # n published pages, one a day up to yesterday, each with two paragraphs
  # of facts and a drawing.
  defp journey(poet, n \\ 14) do
    for i <- 1..n do
      date = Date.add(@today, -(n - i + 1))

      entry =
        published_entry_fixture(poet, %{entry_date: date, place_name: "Town #{i}, Portugal"})

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

      {Repo.reload!(entry), drawing}
    end
  end

  defp key(entry, nth) do
    entry = Journal.preload_entry(entry)
    Enum.at(Journal.Paragraphs.of_sections(entry.sections), nth).key
  end

  defp today_entry(poet), do: entry_fixture(poet, %{entry_date: @today, title: "What stayed?"})

  defp valid_quiz(pages) do
    [{e1, d1}, {e2, _}, {e3, _}, {e4, _} | _] = pages

    %{
      "entry_date" => Date.to_iso8601(@today),
      "notes" => %{
        "high" => "You were there with me the whole way.",
        "mid" => "Half the road stayed with you.",
        "low" => "That is why I write it all down."
      },
      "questions" => [
        %{
          "kind" => "choice",
          "prompt" => "How many bees in the tower of Town 2?",
          "options" => ["Two", "Twelve", "None", "A hundred"],
          "answer" => "a",
          "source_key" => key(e2, 0),
          "aside" => "He named every one."
        },
        %{
          "kind" => "fib",
          "prompt" => "Two truths and a fib.",
          "options" => [
            %{"text" => "Bees in the tower of Town 3", "source_key" => key(e3, 0)},
            %{"text" => "A baker who waits for the tide", "source_key" => key(e4, 1)},
            %{"text" => "A mayor who rides a camel"}
          ],
          "answer" => "c"
        },
        %{
          "kind" => "drawing",
          "prompt" => "Where did I draw this?",
          "media_id" => d1.id,
          "options" => ["Town 9", "Town 1", "Town 5"],
          "answer" => "b"
        },
        %{
          "kind" => "first",
          "prompt" => "Which came first?",
          "options" => [
            %{"text" => "The tide bakery of Town 4", "source_key" => key(e4, 1)},
            %{"text" => "The bees of Town 1", "source_key" => key(e1, 0)},
            %{"text" => "The bees of Town 3", "source_key" => key(e3, 0)}
          ]
        }
      ]
    }
  end

  defp put_quiz(conn, params),
    do: put(conn, ~p"/api/agent/journal_entries/#{Date.to_iso8601(@today)}/quiz", params)

  test "with a journey behind it, the app makes today a quiz day and hands over the material",
       %{conn: conn, poet: poet, user: user} do
    [{read_entry, _} | _] = pages = journey(poet)
    # The reader read one paragraph of the first page through.
    Repo.insert!(%ParagraphRead{
      user_id: user.id,
      journal_entry_id: read_entry.id,
      key: key(read_entry, 1),
      read_on: @today,
      ms: 60_000,
      chars: 80
    })

    travel = conn |> get(~p"/api/agent/context") |> json_response(200) |> Map.fetch!("travel")

    assert travel["day"] == "quiz"
    assert travel["travel_today"] == false
    assert travel["quiz"]["reason"] == "first"
    candidates = travel["quiz"]["candidates"]
    assert length(candidates) == (14 * 2) |> min(18)
    # what they read through is in, and marked
    assert %{"read" => true} = Enum.find(candidates, &(&1["key"] == key(read_entry, 1)))
    assert length(travel["quiz"]["drawings"]) == 6
    assert "Town 14, Portugal" in travel["quiz"]["places"]
    assert length(pages) == 14

    plan = Poets.travel_plan(poet)

    assert DailyJourneyScheduler.trigger_for(poet, plan) =~
             "read skills/travel-and-journal/quiz.md"
  end

  test "too short a journey is an ordinary day, and a quiz put on it is refused",
       %{conn: conn, poet: poet} do
    journey(poet, 13)
    assert Poets.travel_plan(poet).day == "stay"

    today_entry(poet)

    assert %{"error" => "not a quiz day"} =
             conn |> put_quiz(%{"questions" => [], "notes" => %{}}) |> json_response(409)
  end

  test "off for this reader: no quiz day, unless an admin holds the day",
       %{poet: poet} do
    Application.put_env(:traveling_poet, :quiz_enabled, "admins")
    journey(poet)
    assert Poets.travel_plan(poet).day == "stay"

    {:ok, _} = Quizzes.schedule_for(poet, @today)
    assert Poets.travel_plan(poet).day == "quiz"
  end

  test "a good quiz is kept, and the app sets which came first from the dates",
       %{conn: conn, poet: poet} do
    pages = journey(poet)
    today_entry(poet)

    assert %{"ok" => true, "questions" => 4} =
             conn |> put_quiz(valid_quiz(pages)) |> json_response(200)

    quiz = Quizzes.for_day(poet.id, @today)
    assert quiz.status == "written"
    assert quiz.notes["low"] == "That is why I write it all down."

    [choice, fib, drawing, first] = quiz.questions
    assert choice.answer_id == "a"
    assert Question.answer(fib)["text"] == "A mayor who rides a camel"
    assert drawing.answer_id == "b"
    # Town 1 is the earliest of the three moments, whatever the poet thought
    assert first.answer_id == "b"
    {e1, _} = hd(pages)
    assert first.source_entry_id == e1.id
  end

  test "every wrong question is named, so the poet can fix them all at once",
       %{conn: conn, poet: poet} do
    [{e1, _}, {e2, _} | _] = pages = journey(poet)
    today_entry(poet)
    quiz = valid_quiz(pages)

    broken =
      quiz["questions"]
      |> List.replace_at(0, %{hd(quiz["questions"]) | "source_key" => "deadbeefdeadbeef"})
      |> List.replace_at(2, %{Enum.at(quiz["questions"], 2) | "answer" => "a"})
      |> List.replace_at(
        3,
        %{
          Enum.at(quiz["questions"], 3)
          | "options" => [
              %{"text" => "One", "source_key" => key(e1, 0)},
              %{"text" => "Two", "source_key" => key(e1, 1)},
              %{"text" => "Three", "source_key" => key(e2, 0)}
            ]
        }
      )

    %{"fix" => fix} =
      conn |> put_quiz(%{quiz | "questions" => broken}) |> json_response(422)

    assert Enum.any?(fix, &(&1 =~ "question 1: source_key"))

    assert Enum.any?(
             fix,
             &(&1 =~ "question 3: the right answer must be the place this was drawn")
           )

    assert Enum.any?(
             fix,
             &(&1 =~ "question 4: the three moments must come from three different days")
           )

    assert Quizzes.for_day(poet.id, @today).questions == []
  end

  test "the publish reply asks for a missing quiz, and never for places or a drawing",
       %{conn: conn, poet: poet} do
    pages = journey(poet)
    Quizzes.hold_day(poet, @today)
    today_entry(poet)

    publish = fn ->
      conn
      |> post(~p"/api/agent/journal_entries/#{Date.to_iso8601(@today)}/publish")
      |> json_response(200)
    end

    assert publish.()["missing"] == ["quiz"]

    conn |> put_quiz(valid_quiz(pages)) |> json_response(200)
    assert publish.()["missing"] == nil
    assert Quizzes.for_day(poet.id, @today).status == "published"
  end

  test "once the reader has answered, the quiz no longer changes",
       %{conn: conn, poet: poet, user: user} do
    pages = journey(poet)
    today_entry(poet)
    conn |> put_quiz(valid_quiz(pages)) |> json_response(200)
    [question | _] = Quizzes.for_day(poet.id, @today).questions

    Repo.insert!(%Answer{
      question_id: question.id,
      user_id: user.id,
      option_id: "a",
      correct: true
    })

    assert %{"error" => "your companion has already started this quiz"} =
             conn |> put_quiz(valid_quiz(pages)) |> json_response(409)
  end

  test "a quiz day is free and off the road", %{conn: conn, poet: poet, user: user} do
    pages = journey(poet)
    assert {:ok, :free} = Credits.debit_daily_run(user, poet, 1, day: "quiz", scouting: false)

    before = Poets.days_here(poet)
    today_entry(poet)
    conn |> put_quiz(valid_quiz(pages)) |> json_response(200)
    # Counted the way an excursion day is: taken off the days at the place,
    # so the stay keeps all its pages.
    assert Poets.days_here(poet) == before - 1
  end
end
