defmodule TravelingPoet.Repo.Migrations.CreateItineraryStops do
  use Ecto.Migration

  def change do
    create table(:itinerary_stops) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :position, :integer, null: false
      add :place_name, :string, null: false
      add :lat, :float, null: false
      add :lng, :float, null: false
      add :country_code, :string
      add :visited_at, :utc_datetime
      timestamps()
    end

    create index(:itinerary_stops, [:poet_id, :position])
  end
end
