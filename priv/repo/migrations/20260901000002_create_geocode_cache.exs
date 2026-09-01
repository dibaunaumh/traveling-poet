defmodule TravelingPoet.Repo.Migrations.CreateGeocodeCache do
  use Ecto.Migration

  # A table rather than ETS: the app restarts on every deploy, and the backfill
  # mix task runs in its own BEAM and must share the same cache.
  def change do
    create table(:geocode_cache) do
      add :query_hash, :string, null: false
      add :query, :string, null: false
      add :lat, :float
      add :lng, :float
      add :place_name, :string
      add :country_code, :string
      # Misses are cached too, with a TTL. Nominatim allows one request a
      # second for the whole app; without this, one address it has never heard
      # of costs a request on every single re-put, forever.
      add :found, :boolean, null: false, default: false
      add :looked_up_at, :utc_datetime, null: false

      timestamps()
    end

    create unique_index(:geocode_cache, [:query_hash])
  end
end
