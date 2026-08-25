defmodule TravelingPoet.Journal.Section do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(illustration description poem art_culture products kindness)

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
    |> validate_required([:journal_entry_id, :kind, :position])
    |> validate_inclusion(:kind, @kinds)
  end
end
