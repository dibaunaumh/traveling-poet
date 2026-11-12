defmodule TravelingPoet.Journal.Section do
  use Ecto.Schema
  import Ecto.Changeset

  # highlights: what an excursion brought back (talks, papers, products),
  # where a day at a place would have art_culture and products.
  # local_tip: a local reader's tips, translated by the poet, credited by the
  # app from metadata (LocalVoices, card-10).
  @kinds ~w(illustration description poem art_culture products kindness highlights local_tip)

  schema "journal_sections" do
    field :kind, :string
    field :position, :integer, default: 0
    field :title, :string
    field :body, :string
    field :media_id, :integer
    field :metadata, :map, default: %{}

    belongs_to :journal_entry, TravelingPoet.Journal.Entry

    timestamps()
  end

  def kinds, do: @kinds

  @doc false
  def changeset(section, attrs) do
    section
    |> cast(attrs, [:journal_entry_id, :kind, :position, :title, :body, :media_id, :metadata])
    |> update_change(:title, &TravelingPoet.Journal.Blank.clean/1)
    |> validate_required([:journal_entry_id, :kind, :position])
    |> validate_inclusion(:kind, @kinds)
  end
end
