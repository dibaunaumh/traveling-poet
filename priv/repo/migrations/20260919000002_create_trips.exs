defmodule TravelingPoet.Repo.Migrations.CreateTrips do
  use Ecto.Migration

  # A trip the companion is going on, found on their calendar (or, later,
  # entered by hand). The suggestion and the plan are one row: a trip starts
  # "suggested", becomes "planned" when the companion asks the poet to scout
  # it, and its stops hang off it in itinerary_stops. Dismissed trips stay so
  # a re-sync neither duplicates nor resurrects them. What is kept from the
  # calendar is dates, event ids and locations; never titles or attendees.
  def change do
    create table(:trips) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      # "Rome" / "Rome and Florence": derived from the destinations, never an event title
      add :name, :string, null: false
      # suggested | planned | scouting | done | dismissed
      add :status, :string, null: false, default: "suggested"
      # calendar | settings
      add :source, :string, null: false, default: "calendar"
      add :start_date, :date, null: false
      add :end_date, :date, null: false
      # when the poet sets out to scout (start minus the stays), once planned
      add :scout_from, :date
      # %{"items" => [%{place_name, lat, lng, country_code, arrive_on, depart_on}]}
      add :destinations, :map, default: %{}
      # the calendar event ids the trip was built from: the match key on re-sync
      add :event_ids, {:array, :string}, default: "[]", null: false
      # %{"events" => [%{id, ical_uid, kind, start, end, location}]}; no titles
      add :signals, :map, default: %{}
      # home as it was when the trip was found
      add :home_place_name, :string
      add :suggested_at, :utc_datetime
      # the last time the calendar changed the dates or destinations
      add :changed_at, :utc_datetime
      add :decided_at, :utc_datetime
      add :calendar_gone_at, :utc_datetime
      timestamps()
    end

    create index(:trips, [:poet_id, :status])

    alter table(:itinerary_stops) do
      add :trip_id, references(:trips, on_delete: :delete_all)
    end

    create index(:itinerary_stops, [:trip_id])
  end
end
