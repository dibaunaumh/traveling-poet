defmodule TravelingPoet.Quizzes.Answer do
  @moduledoc """
  The owner's answer to one question: one try, kept. Only the owner's are
  stored (dec-021); a public visitor plays in the page and nothing is kept.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "quiz_answers" do
    field :option_id, :string
    field :correct, :boolean

    belongs_to :question, TravelingPoet.Quizzes.Question
    belongs_to :user, TravelingPoet.Accounts.User

    timestamps(updated_at: false)
  end

  @doc false
  def changeset(answer, attrs) do
    answer
    |> cast(attrs, [:question_id, :user_id, :option_id, :correct])
    |> validate_required([:question_id, :user_id, :option_id, :correct])
    |> unique_constraint([:question_id, :user_id])
  end
end
