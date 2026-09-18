defmodule TravelingPoet.Trips.Trip do
  @moduledoc """
  A trip the companion is going on, and what the poet does about it.

  Found on their Google Calendar (`source` "calendar") or entered by hand
  ("settings"). Suggestion and plan are one row: `status` goes
  suggested -> planned -> scouting -> done, or -> dismissed. `destinations`
  are the cities to scout, in order of arrival; the stops the poet actually
  follows are `itinerary_stops` rows with this `trip_id`.

  `event_ids` are the calendar events the trip was built from and the key a
  re-sync matches on; `signals` keeps their dates, kinds and locations for
  the record. Neither holds an event's title.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(suggested planned scouting done dismissed)
  @sources ~w(calendar settings)

  schema "trips" do
    field :name, :string
    field :status, :string, default: "suggested"
    field :source, :string, default: "calendar"
    field :start_date, :date
    field :end_date, :date
    field :scout_from, :date
    field :destinations, :map, default: %{}
    field :event_ids, {:array, :string}, default: []
    field :signals, :map, default: %{}
    field :home_place_name, :string
    field :suggested_at, :utc_datetime
    field :changed_at, :utc_datetime
    field :decided_at, :utc_datetime
    field :calendar_gone_at, :utc_datetime

    belongs_to :poet, TravelingPoet.Poets.Poet
    has_many :stops, TravelingPoet.Poets.ItineraryStop

    timestamps()
  end

  def statuses, do: @statuses

  @doc false
  def changeset(trip, attrs) do
    trip
    |> cast(attrs, [
      :poet_id,
      :name,
      :status,
      :source,
      :start_date,
      :end_date,
      :scout_from,
      :destinations,
      :event_ids,
      :signals,
      :home_place_name,
      :suggested_at,
      :changed_at,
      :decided_at,
      :calendar_gone_at
    ])
    |> validate_required([:poet_id, :name, :status, :source, :start_date, :end_date])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_dates()
  end

  defp validate_dates(changeset) do
    start_date = get_field(changeset, :start_date)
    end_date = get_field(changeset, :end_date)

    if start_date && end_date && Date.compare(end_date, start_date) == :lt,
      do: add_error(changeset, :end_date, "ends before it starts"),
      else: changeset
  end

  @doc "The destinations as a list of maps with string keys, oldest arrival first."
  def destinations(%__MODULE__{destinations: %{"items" => items}}) when is_list(items), do: items
  def destinations(_trip), do: []
end
