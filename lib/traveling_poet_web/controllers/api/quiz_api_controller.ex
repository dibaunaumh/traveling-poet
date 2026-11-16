defmodule TravelingPoetWeb.Api.QuizApiController do
  @moduledoc """
  The poet puts its quiz on a quiz day's entry (`journal_put_quiz`). Only on
  a day the app chose (`travel.day == "quiz"`); every question is checked
  against what was really written, and the reply names each one to fix, so
  the poet corrects and sends the whole quiz again.
  """

  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.{Journal, Poets, Quizzes}

  def put(conn, %{"date" => date_str} = params) do
    user = conn.assigns.agent_user

    with {:ok, date} <- Date.from_iso8601(to_string(date_str)),
         %Poets.Poet{} = poet <- Poets.get_poet_by_user(user.id),
         {:entry, %Journal.Entry{} = entry} <- {:entry, Journal.get_entry(poet.id, date)} do
      case Quizzes.put(poet, entry, params) do
        {:ok, quiz} ->
          Logger.info("Poet #{poet.id} put a quiz of #{length(quiz.questions)} on #{date}")

          json(conn, %{
            ok: true,
            questions: length(quiz.questions),
            note:
              if(entry.status == "published",
                do: "saved on your published page",
                else: "saved; now journal_publish #{date}"
              )
          })

        {:error, {:invalid, errors}} ->
          conn
          |> put_status(422)
          |> json(%{
            error: "the quiz was not saved",
            fix: errors,
            note: "fix each of these and send the whole quiz again"
          })

        {:error, :not_quiz_day} ->
          conn
          |> put_status(409)
          |> json(%{
            error: "not a quiz day",
            note:
              "the app decides quiz days (travel.day in get_poet_context); write today's page as usual"
          })

        {:error, :answered} ->
          conn
          |> put_status(409)
          |> json(%{
            error: "your companion has already started this quiz",
            note: "it can no longer change; leave it as it is"
          })
      end
    else
      {:error, _} ->
        conn |> put_status(422) |> json(%{error: "invalid date, expected YYYY-MM-DD"})

      nil ->
        conn |> put_status(404) |> json(%{error: "no poet configured"})

      {:entry, nil} ->
        conn
        |> put_status(404)
        |> json(%{error: "no entry for #{date_str}; call journal_upsert_entry first"})
    end
  end
end
