defmodule TravelingPoet.ReaderNote.Suggestion do
  @moduledoc """
  A line the poet suggests for the reader's note: `add` a sentence, or
  `strike` one that is already in it. The reader accepts or declines; a
  declined line is never suggested again.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(add strike)
  @statuses ~w(pending accepted declined)

  schema "reader_note_suggestions" do
    field :kind, :string
    field :text, :string
    field :reason, :string
    field :status, :string, default: "pending"

    belongs_to :poet, TravelingPoet.Poets.Poet

    timestamps()
  end

  def changeset(suggestion, attrs) do
    suggestion
    |> cast(attrs, [:poet_id, :kind, :text, :reason, :status])
    |> update_change(:text, &String.trim/1)
    |> validate_required([:poet_id, :kind, :text])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:text, min: 3, max: 300)
    |> validate_length(:reason, max: 300)
  end
end
