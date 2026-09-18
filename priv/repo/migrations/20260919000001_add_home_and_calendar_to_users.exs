defmodule TravelingPoet.Repo.Migrations.AddHomeAndCalendarToUsers do
  use Ecto.Migration

  # Google Calendar, read to find the companion's upcoming trips. A trip is a
  # stretch of days somewhere far from home, so the app needs to know where
  # home is: the companion names a city when connecting (the app never had a
  # user location before; the poet's start city is the poet's). The calendar
  # grant itself lives on the shared google_* columns.
  def change do
    alter table(:users) do
      add :home_place_name, :string
      add :home_lat, :float
      add :home_lng, :float
      add :home_country_code, :string
      add :calendar_connected_at, :utc_datetime
      add :calendar_synced_at, :utc_datetime
      # nil | reconnect | forbidden | failed
      add :calendar_error, :string
    end

    # The city (and country) behind a geocoded address, so a hotel's street
    # address can be named as its city in a trip suggestion.
    alter table(:geocode_cache) do
      add :city, :string
      add :country, :string
    end
  end
end
