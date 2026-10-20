defmodule TravelingPoet.ReaderNote.Note do
  @moduledoc """
  The "About you" note (card-125): a few plain sentences about the reader,
  one per poet. `written_by` is "poet" while it is the poet's draft and
  "reader" once the reader saved it or accepted a line; from then on the
  poet may only suggest. `understood` is what the app took from it on the
  last save (`ReaderNote.Extractor`), shown back under the note.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @authors ~w(poet reader)
  @max_chars 2_000

  schema "reader_notes" do
    field :text, :string
    field :written_by, :string, default: "poet"
    field :understood, :map, default: %{}
    field :understood_at, :utc_datetime

    belongs_to :poet, TravelingPoet.Poets.Poet

    timestamps()
  end

  def max_chars, do: @max_chars

  def changeset(note, attrs) do
    note
    |> cast(attrs, [:poet_id, :text, :written_by, :understood, :understood_at])
    |> update_change(:text, &String.trim/1)
    |> validate_required([:poet_id, :text, :written_by])
    |> validate_length(:text, max: @max_chars)
    |> validate_inclusion(:written_by, @authors)
    |> unique_constraint(:poet_id)
  end
end
