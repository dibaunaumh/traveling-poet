defmodule TravelingPoet.Quizzes.Question do
  @moduledoc """
  One question of a quiz. Every kind is answered with one tap on one option:

    * `choice`: which is true? Three or four options.
    * `fib`: two truths and a fib. Three statements; the answer is the fib.
    * `drawing`: where did I draw this? One of the poet's past drawings
      (`media_id`) and three or four places.

  A fourth kind, `first` (which came first?), was dropped after the first
  quiz on prod (2026-11-16): readers took it for a list to drag into order.
  The poet can no longer write one (`kinds/0`), but the one already played
  still renders (`played_kinds/0`).

  `options` are `%{"id", "text", "source_key", "source_entry_id"}`; `id` is
  "a", "b", "c", "d". `source_entry_id` / `source_key` point at the page and
  paragraph the fact came from, for the reader's "read it again" link.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(choice fib drawing)
  @played_kinds @kinds ++ ~w(first)

  schema "quiz_questions" do
    field :position, :integer
    field :kind, :string
    field :prompt, :string
    field :options, {:array, :map}, default: []
    field :answer_id, :string
    field :aside, :string
    field :source_key, :string

    belongs_to :quiz, TravelingPoet.Quizzes.Quiz
    belongs_to :source_entry, TravelingPoet.Journal.Entry
    belongs_to :media, TravelingPoet.Journal.Media

    timestamps()
  end

  @doc "The kinds a poet can write."
  def kinds, do: @kinds

  @doc "Every kind a stored question can have, retired ones included."
  def played_kinds, do: @played_kinds

  @doc false
  def changeset(question, attrs) do
    question
    |> cast(attrs, [
      :quiz_id,
      :position,
      :kind,
      :prompt,
      :options,
      :answer_id,
      :aside,
      :source_entry_id,
      :source_key,
      :media_id
    ])
    |> validate_required([:quiz_id, :position, :kind, :prompt, :options, :answer_id])
    |> validate_inclusion(:kind, @kinds)
  end

  @doc "The option the answer names."
  def answer(%__MODULE__{options: options, answer_id: id}),
    do: Enum.find(options, &(&1["id"] == id))
end
