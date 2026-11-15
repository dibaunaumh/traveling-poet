defmodule TravelingPoet.Quizzes.Quiz do
  @moduledoc """
  A quiz day: the day's entry is a quiz on the curious facts of past pages.
  The row marks the entry the way an excursion row does.

  `status`: "queued" (the app holds the day for a quiz; no questions yet),
  "written" (the poet put its questions on today's entry), "published".
  `source`: "cadence" (`Quizzes.Cadence` chose the day) or "admin"
  (`Quizzes.schedule_for/2`). `notes` are the poet's closing notes by score
  tier, written with the questions so finishing needs no model call.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued written published)
  @sources ~w(cadence admin)
  @tiers ~w(high mid low)

  schema "quizzes" do
    field :status, :string, default: "queued"
    field :source, :string, default: "cadence"
    field :scheduled_for, :date
    field :notes, :map, default: %{}

    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :journal_entry, TravelingPoet.Journal.Entry
    has_many :questions, TravelingPoet.Quizzes.Question, preload_order: [asc: :position]

    timestamps()
  end

  def tiers, do: @tiers

  @doc false
  def changeset(quiz, attrs) do
    quiz
    |> cast(attrs, [:poet_id, :journal_entry_id, :status, :source, :scheduled_for, :notes])
    |> validate_required([:poet_id, :status, :source, :scheduled_for])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> unique_constraint([:poet_id, :scheduled_for])
    |> unique_constraint(:journal_entry_id)
  end
end
