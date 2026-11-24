defmodule TravelingPoet.Repo.Migrations.AddAwayFromHome do
  use Ecto.Migration

  # card-78: where the reader is now, reported by their own device while the
  # app is open and only after they switch it on, so Near you can look
  # around them when they are away from home.
  def change do
    alter table(:users) do
      add :away_aware, :boolean, default: false, null: false
      add :here_lat, :float
      add :here_lng, :float
      add :here_place_name, :string
      add :here_at, :utc_datetime
    end

    # Which place a batch of picks was found around: nil is home.
    alter table(:near_home_picks) do
      add :around_name, :string
      add :around_lat, :float
      add :around_lng, :float
    end
  end
end
