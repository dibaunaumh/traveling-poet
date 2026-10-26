defmodule TravelingPoet.Feedback.NpsResponse do
  @moduledoc """
  A reader's answer to "How likely are you to recommend Traveling Poet to a
  friend?" (card-137): a score from 0 to 10, stored the moment it is tapped,
  and the optional words they add after it. `journal_entry_id` is the page it
  was asked under.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @comment_max 4000

  schema "nps_responses" do
    field :score, :integer
    field :comment, :string

    belongs_to :user, TravelingPoet.Accounts.User
    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  def changeset(response, attrs) do
    response
    |> cast(attrs, [:user_id, :score, :comment, :journal_entry_id])
    |> update_change(:comment, &String.trim/1)
    |> validate_required([:user_id, :score])
    |> validate_number(:score, greater_than_or_equal_to: 0, less_than_or_equal_to: 10)
    |> validate_length(:comment, max: @comment_max)
  end

  @doc "Promoter (9-10), passive (7-8) or detractor (0-6), as NPS counts them."
  def bucket(score) when score >= 9, do: :promoter
  def bucket(score) when score >= 7, do: :passive
  def bucket(_score), do: :detractor
end
