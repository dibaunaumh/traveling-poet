defmodule TravelingPoet.Poets.ItineraryStop do
  @moduledoc """
  A planned place on a Trip Scout poet's route (mode "scout"): the user's
  intended visit order; the poet pre-visits them one by one. `visited_at`
  nil = still pending.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # "settings": typed into the itinerary by the user. "chat": a detour the poet
  # added because the companion asked for it in conversation.
  @sources ~w(settings chat)

  schema "itinerary_stops" do
    field :position, :integer
    field :place_name, :string
    field :lat, :float
    field :lng, :float
    field :country_code, :string
    field :visited_at, :utc_datetime
    field :source, :string, default: "settings"

    belongs_to :poet, TravelingPoet.Poets.Poet

    timestamps()
  end

  def sources, do: @sources

  @doc false
  def changeset(stop, attrs) do
    stop
    |> cast(attrs, [
      :poet_id,
      :position,
      :place_name,
      :lat,
      :lng,
      :country_code,
      :visited_at,
      :source
    ])
    |> validate_required([:poet_id, :position, :place_name, :lat, :lng])
    |> validate_inclusion(:source, @sources)
    |> validate_number(:lat, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:lng, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
  end
end
