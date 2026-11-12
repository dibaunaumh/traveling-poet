defmodule TravelingPoet.LocalVoices.Question do
  @moduledoc """
  One visiting poet's question to one local reader (card-10): "you live
  near here, any tips?". The app writes the question; the reader answers in
  a short form (`LocalQuestionLive`).

  `status`: "open" until they answer ("answered") or wave it off
  ("declined"). An open question older than `LocalVoices.open_days/0` is
  over; nothing sweeps it. `used_entry_id` is the page the poet put the tip
  on, as a `local_tip` section.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(open answered declined)

  schema "local_questions" do
    field :place_name, :string
    field :status, :string, default: "open"
    field :answer, :string
    field :answered_at, :utc_datetime

    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :user, TravelingPoet.Accounts.User
    belongs_to :used_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  @doc false
  def changeset(question, attrs) do
    question
    |> cast(attrs, [:poet_id, :user_id, :place_name, :status])
    |> validate_required([:poet_id, :user_id, :place_name])
    |> validate_inclusion(:status, @statuses)
  end

  @doc false
  def answer_changeset(question, attrs) do
    question
    |> cast(attrs, [:answer])
    |> update_change(:answer, &String.trim/1)
    |> validate_required([:answer])
    |> validate_length(:answer, min: 3, max: 1500)
    |> put_change(:status, "answered")
    |> put_change(:answered_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end
end
