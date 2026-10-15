defmodule TravelingPoet.Guide.StayArea do
  @moduledoc """
  A neighbourhood the poet weighed as a base for the reader's trip, on a
  where-to-stay day (card-90). The poet writes what it is like and who it
  suits; the app finds it on the map and counts what lies within a short
  walk (`TravelingPoet.Guide.Stay`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "stay_areas" do
    field :city, :string
    field :name, :string
    field :summary, :string
    field :best_for, :string
    field :tradeoffs, :string
    field :recommended, :boolean, default: false
    field :lat, :float
    field :lng, :float
    field :geocode_status, :string, default: "pending"
    field :position, :integer, default: 0

    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :journal_entry, TravelingPoet.Journal.Entry
    # The shared neighbourhood item (Spaces, kb-002); set by Spaces.Ingest.
    belongs_to :item, TravelingPoet.Spaces.Item

    timestamps()
  end

  @doc false
  def changeset(area, attrs) do
    area
    |> cast(attrs, [
      :poet_id,
      :journal_entry_id,
      :city,
      :name,
      :summary,
      :best_for,
      :tradeoffs,
      :recommended,
      :lat,
      :lng,
      :geocode_status,
      :position
    ])
    |> validate_required([:poet_id, :journal_entry_id, :city, :name])
    |> validate_length(:name, max: 120)
    |> validate_inclusion(:geocode_status, ~w(pending ok failed))
  end

  def mapped?(%__MODULE__{lat: lat, lng: lng}), do: is_number(lat) and is_number(lng)
end
