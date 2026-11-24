defmodule TravelingPoet.Repo.Migrations.AddTripHere do
  use Ecto.Migration

  # card-78, step 2 of being away: where the reader's calendar puts them
  # today, written by each calendar sync, so Near you can look around a trip
  # city with no device location at all. Until is the trip's last day.
  def change do
    alter table(:users) do
      add :trip_here_name, :string
      add :trip_here_lat, :float
      add :trip_here_lng, :float
      add :trip_here_until, :date
    end
  end
end
