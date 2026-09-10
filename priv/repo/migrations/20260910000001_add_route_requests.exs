defmodule TravelingPoet.Repo.Migrations.AddRouteRequests do
  use Ecto.Migration

  # Route requests made in chat become data the daily run reads, instead of a
  # promise the model has to remember: a hold ("stay longer here") and where
  # a stop came from (a detour the poet added at the companion's request, vs
  # the itinerary typed in Settings).
  def change do
    alter table(:poets) do
      add :hold_until, :date
    end

    alter table(:itinerary_stops) do
      add :source, :string, null: false, default: "settings"
    end
  end
end
