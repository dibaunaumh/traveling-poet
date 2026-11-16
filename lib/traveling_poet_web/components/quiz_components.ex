defmodule TravelingPoetWeb.QuizComponents do
  @moduledoc """
  A quiz day's quiz on the notebook page (card-140): one question at a time,
  a row of stamp rings that fill as the reader gets them right (a passport
  page for what stayed with them), and at the end the score, a title and the
  poet's closing note for that score, written in advance by the poet.

  The right answer is only ever rendered for a question already answered:
  before that the page holds the options and nothing else, so reading the
  page source gives nothing away. The poet's words are rendered as text
  (HEEx escapes them), never as HTML.

  `TravelingPoetWeb.QuizPlay` is the LiveView half, shared by the owner's
  journal (answers kept) and a public journal (played in the page only).
  """

  use Phoenix.Component
  use Gettext, backend: TravelingPoetWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: TravelingPoetWeb.Endpoint,
    router: TravelingPoetWeb.Router,
    statics: TravelingPoetWeb.static_paths()

  alias TravelingPoet.Quizzes
  alias TravelingPoet.Quizzes.Question

  attr :quiz, :map, required: true
  attr :answers, :map, required: true, doc: "%{question_id => option_id}"
  attr :reveal, :any, default: nil, doc: "the question just answered, shown with its answer"
  attr :poet, :map, required: true
  attr :page_path, :any, required: true, doc: "fn date -> the page of that date"
  attr :saves, :boolean, default: false, doc: "the owner: answers are kept"

  def quiz_card(assigns) do
    questions = assigns.quiz.questions
    current = current(questions, assigns.answers, assigns.reveal)

    assigns =
      assigns
      |> assign(:current, current)
      |> assign(:position, current && Enum.find_index(questions, &(&1.id == current.id)) + 1)
      |> assign(:score, Quizzes.score(assigns.quiz, assigns.answers))
      |> assign(:upcoming_drawings, upcoming_drawings(questions, assigns.answers, current))

    ~H"""
    <section id="quiz" class="quiz-card" aria-live="polite">
      <p class="quiz-kicker">{dgettext("journal", "A little quiz")}</p>
      <.stamps questions={@quiz.questions} answers={@answers} reveal={@reveal} />

      <.question
        :if={@current}
        question={@current}
        position={@position}
        of={length(@quiz.questions)}
        chosen={@answers[@current.id]}
        last={@position == length(@quiz.questions)}
        page_path={@page_path}
      />

      <.final
        :if={is_nil(@current)}
        quiz={@quiz}
        score={@score}
        answers={@answers}
        poet={@poet}
        page_path={@page_path}
      />

      <%!-- The drawings of the questions still ahead start downloading now,
           while the reader is on the earlier ones, so a drawing question
           opens on a drawing already there. --%>
      <div :if={@upcoming_drawings != []} class="quiz-preload" aria-hidden="true">
        <img :for={id <- @upcoming_drawings} src={~p"/media/#{id}"} alt="" />
      </div>

      <p class="quiz-privacy">
        {if @saves,
          do: dgettext("journal", "Your answers stay between you and %{poet}.", poet: @poet.name),
          else: dgettext("journal", "Play along. Your answers are not saved.")}
      </p>
    </section>
    """
  end

  defp upcoming_drawings(questions, answers, current) do
    for q <- questions,
        q.media_id,
        not Map.has_key?(answers, q.id),
        is_nil(current) or q.id != current.id,
        uniq: true,
        do: q.media_id
  end

  # The question on show: the one just answered while its answer is up,
  # else the first one without an answer; nil once every one has one.
  defp current(questions, answers, reveal) do
    Enum.find(questions, &(&1.id == reveal)) ||
      Enum.find(questions, &(not Map.has_key?(answers, &1.id)))
  end

  attr :questions, :list, required: true
  attr :answers, :map, required: true
  attr :reveal, :any, default: nil

  defp stamps(assigns) do
    ~H"""
    <ol class="quiz-stamps" aria-label={dgettext("journal", "Your stamps")}>
      <li
        :for={q <- @questions}
        class={[
          "quiz-stamp",
          stamp_state(q, @answers),
          q.id == @reveal and Quizzes.right?(q, @answers[q.id]) and "is-new"
        ]}
        title={stamp_place(q)}
      >
        <span :if={Quizzes.right?(q, @answers[q.id])} class="quiz-stamp-name">
          {short_place(stamp_place(q))}
        </span>
      </li>
    </ol>
    """
  end

  defp stamp_state(q, answers) do
    cond do
      not Map.has_key?(answers, q.id) -> "is-open"
      Quizzes.right?(q, answers[q.id]) -> "is-right"
      true -> "is-missed"
    end
  end

  defp stamp_place(%Question{source_entry: %{place_name: place}}) when is_binary(place), do: place
  defp stamp_place(_q), do: nil

  defp short_place(nil), do: dgettext("journal", "Right!")
  defp short_place(place), do: place |> String.split(",") |> hd() |> String.trim()

  attr :question, :map, required: true
  attr :position, :integer, required: true
  attr :of, :integer, required: true
  attr :chosen, :string, default: nil
  attr :last, :boolean, default: false
  attr :page_path, :any, required: true

  defp question(assigns) do
    assigns =
      assign(
        assigns,
        :right,
        assigns.chosen && Quizzes.right?(assigns.question, assigns.chosen)
      )

    ~H"""
    <div id={"quiz-q-#{@question.id}"} class="quiz-question">
      <p class="quiz-count">
        {dgettext("journal", "Question %{n} of %{of}", n: @position, of: @of)}
        <span class="quiz-kind">{kind_label(@question.kind)}</span>
      </p>

      <figure
        :if={@question.media}
        id={"quiz-drawing-#{@question.id}"}
        class="quiz-drawing"
        phx-hook="QuizDrawing"
        phx-update="ignore"
      >
        <span class="quiz-drawing-wait">
          {dgettext("journal", "Finding the drawing in my notebook…")}
        </span>
        <img src={~p"/media/#{@question.media.id}"} alt="" fetchpriority="high" />
      </figure>

      <p class="quiz-prompt">{@question.prompt}</p>

      <div class="quiz-options">
        <button
          :for={option <- @question.options}
          type="button"
          id={"quiz-q-#{@question.id}-#{option["id"]}"}
          class={[
            "quiz-option",
            @chosen && option["id"] == @question.answer_id && "is-right",
            @chosen && option["id"] == @chosen && !@right && "is-wrong"
          ]}
          phx-click="quiz_answer"
          phx-value-question={@question.id}
          phx-value-option={option["id"]}
          disabled={@chosen != nil}
        >
          <span class="quiz-letter">{String.upcase(option["id"])}</span>
          <span>{option["text"]}</span>
        </button>
      </div>

      <div :if={@chosen} class="quiz-reveal">
        <p class={["quiz-verdict", if(@right, do: "is-right", else: "is-wrong")]}>
          {if @right,
            do: dgettext("journal", "Right!"),
            else:
              dgettext("journal", "Not quite. It was %{letter}.",
                letter: String.upcase(@question.answer_id)
              )}
        </p>
        <p :if={@question.aside} class="quiz-aside">{@question.aside}</p>
        <.read_again
          entry={@question.source_entry}
          key={@question.source_key}
          page_path={@page_path}
        />
        <button type="button" class="btn btn-sm btn-primary quiz-next" phx-click="quiz_next">
          {if @last,
            do: dgettext("journal", "See your score"),
            else: dgettext("journal", "Next question")}
        </button>
      </div>
    </div>
    """
  end

  defp kind_label("choice"), do: dgettext("journal", "Which is true?")
  defp kind_label("fib"), do: dgettext("journal", "Two truths and a fib: which did I make up?")
  defp kind_label("drawing"), do: dgettext("journal", "Where did I draw this?")
  defp kind_label("first"), do: dgettext("journal", "Which came first?")
  defp kind_label(_), do: nil

  attr :entry, :any, required: true
  attr :key, :string, default: nil, doc: "the paragraph to open the page at (ParagraphFocus)"
  attr :page_path, :any, required: true

  defp read_again(%{entry: %{entry_date: %Date{}}} = assigns) do
    path = assigns.page_path.(assigns.entry.entry_date)
    assigns = assign(assigns, :to, if(assigns.key, do: "#{path}?p=#{assigns.key}", else: path))

    ~H"""
    <.link navigate={@to} class="quiz-read-again">
      {dgettext("journal", "Read it again: %{page}", page: page_name(@entry))}
    </.link>
    """
  end

  defp read_again(assigns), do: ~H""

  defp page_name(entry) do
    date = TravelingPoet.Locale.format_date(entry.entry_date, :short)

    case entry.place_name do
      place when is_binary(place) and place != "" -> "#{short_place(place)}, #{date}"
      _ -> date
    end
  end

  attr :quiz, :map, required: true
  attr :score, :map, required: true
  attr :answers, :map, required: true
  attr :poet, :map, required: true
  attr :page_path, :any, required: true

  defp final(assigns) do
    missed =
      assigns.quiz.questions
      |> Enum.reject(&Quizzes.right?(&1, assigns.answers[&1.id]))
      |> Enum.map(& &1.source_entry)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    assigns = assign(assigns, :missed, missed)

    ~H"""
    <div id="quiz-final" class={["quiz-final", "is-#{@score.tier}"]}>
      <p :if={@score.tier == "high"} class="quiz-bravo" aria-hidden="true">
        {dgettext("journal", "Bravo!")}
      </p>
      <p class="quiz-score">
        {dgettext("journal", "%{right} of %{of}", right: @score.right, of: @score.of)}
      </p>
      <p class="quiz-title">{tier_title(@score.tier)}</p>
      <blockquote :if={@quiz.notes[@score.tier]} class="quiz-note">
        <p>{@quiz.notes[@score.tier]}</p>
        <footer>{@poet.name}</footer>
      </blockquote>
      <div :if={@poet.is_public} class="quiz-share">
        <span>{dgettext("journal", "Share your score")}</span>
        <TravelingPoetWeb.ShareComponents.share_menu
          id="quiz-share"
          url={url(~p"/p/#{@poet.slug}/#{Date.to_iso8601(@quiz.scheduled_for)}")}
          title={
            dgettext("journal", "I remembered %{right} of %{of} from %{poet}'s journey",
              right: @score.right,
              of: @score.of,
              poet: @poet.name
            )
          }
          text={dgettext("journal", "Can you do better?")}
        />
      </div>
      <div :if={@missed != []} class="quiz-missed">
        <p>{dgettext("journal", "Pages to look back at")}</p>
        <ul>
          <li :for={entry <- @missed}>
            <.link navigate={@page_path.(entry.entry_date)}>{page_name(entry)}</.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp tier_title("high"), do: dgettext("journal", "Keeper of the notebook")
  defp tier_title("mid"), do: dgettext("journal", "Fellow traveler")
  defp tier_title(_), do: dgettext("journal", "Fresh off the train")
end
