defmodule TravelingPoet.Poets.PathPoint do
  use Ecto.Schema
  import Ecto.Changeset

  schema "path_points" do
    field :lat, :float
    field :lng, :float
    field :place_name, :string
    field :country_code, :string
    field :arrived_at, :utc_datetime
    field :departed_at, :utc_datetime
    field :position, :integer

    belongs_to :poet, TravelingPoet.Poets.Poet

    timestamps()
  end

  @doc false
  def changeset(path_point, attrs) do
    path_point
    |> cast(attrs, [
      :poet_id,
      :lat,
      :lng,
      :place_name,
      :country_code,
      :arrived_at,
      :departed_at,
      :position
    ])
    |> validate_required([:poet_id, :lat, :lng, :arrived_at, :position])
    |> validate_number(:lat, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:lng, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
  end
end
