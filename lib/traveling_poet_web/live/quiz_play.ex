defmodule TravelingPoetWeb.QuizPlay do
  @moduledoc """
  The LiveView half of a quiz day's quiz (card-140), shared by the owner's
  journal and a public journal. Each assigns the quiz from its entry bundle
  and routes `quiz_answer` and `quiz_next` here.

  The owner's answers are kept (`Quizzes.answer/4`), one try per question,
  and come back on every visit. Anyone else plays in the page: their
  answers live in the socket and are gone when they leave (dec-021).
  """

  import Phoenix.Component, only: [assign: 3]

  alias TravelingPoet.Quizzes

  @doc "`owner`: the signed-in poet's own reader, whose answers are kept; nil for anyone else."
  def assign_quiz(socket, quiz, owner) do
    answers = if quiz && owner, do: Quizzes.answers_for(quiz, owner.id), else: %{}

    socket
    |> assign(:quiz, quiz)
    |> assign(:quiz_owner, owner)
    |> assign(:quiz_answers, answers)
    |> assign(:quiz_reveal, nil)
  end

  def handle_event("quiz_answer", %{"question" => qid, "option" => option}, socket) do
    %{quiz: quiz, quiz_answers: answers, quiz_owner: owner} = socket.assigns

    with %{} <- quiz,
         {id, ""} <- Integer.parse(to_string(qid)),
         %{} = question <- Enum.find(quiz.questions, &(&1.id == id)),
         false <- Map.has_key?(answers, id),
         true <- Enum.any?(question.options, &(&1["id"] == option)) do
      answers =
        case owner && Quizzes.answer(quiz, owner, id, option) do
          {:ok, kept} -> kept
          _ -> Map.put(answers, id, option)
        end

      {:noreply, socket |> assign(:quiz_answers, answers) |> assign(:quiz_reveal, id)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("quiz_next", _params, socket),
    do: {:noreply, assign(socket, :quiz_reveal, nil)}
end
