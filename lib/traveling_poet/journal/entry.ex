defmodule TravelingPoet.Journal.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(draft published)

  schema "journal_entries" do
    field :entry_date, :date
    field :title, :string
    field :place_name, :string
    field :lat, :float
    field :lng, :float
    field :status, :string, default: "draft"
    field :published_at, :utc_datetime
    field :weather, :map, default: %{}
    field :sources, :map, default: %{}

    belongs_to :poet, TravelingPoet.Poets.Poet
    has_many :sections, TravelingPoet.Journal.Section, foreign_key: :journal_entry_id
    has_many :reactions, TravelingPoet.Journal.Reaction, foreign_key: :journal_entry_id

    timestamps()
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :poet_id,
      :entry_date,
      :title,
      :place_name,
      :lat,
      :lng,
      :status,
      :published_at,
      :weather,
      :sources
    ])
    |> validate_required([:poet_id, :entry_date])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:poet_id, :entry_date])
  end
end
