defmodule TravelingPoet.Books.Edition do
  @moduledoc """
  A composed edition of the book: the matter the poet wrote for it
  (dedication, foreword, chapter openers, epilogue, pull quotes) and the
  state of the paid turn that wrote it.

  `composing` while the turn runs, `ready` once the matter landed, `failed`
  (and refunded) when it did not. The matter is validated on the way in by
  `Books.Matter`; this schema only stores it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(composing ready failed)
  @kinds ~w(composed)

  schema "book_editions" do
    field :kind, :string, default: "composed"
    field :status, :string, default: "composing"
    field :matter, :map, default: %{}
    field :chapter_count, :integer, default: 0
    field :credits_charged, :integer, default: 0
    field :composed_at, :utc_datetime
    field :error, :string

    belongs_to :poet, TravelingPoet.Poets.Poet

    timestamps()
  end

  def statuses, do: @statuses

  @doc false
  def changeset(edition, attrs) do
    edition
    |> cast(attrs, [
      :poet_id,
      :kind,
      :status,
      :matter,
      :chapter_count,
      :credits_charged,
      :composed_at,
      :error
    ])
    |> validate_required([:poet_id, :kind, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:error, max: 255)
    |> foreign_key_constraint(:poet_id)
  end
end
