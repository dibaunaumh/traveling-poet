defmodule TravelingPoet.Repo.Migrations.AddEraAndKindToPlaces do
  use Ecto.Migration

  def change do
    alter table(:places) do
      # What the poet reported beyond a place (Spaces phase 2): a kind other
      # than place or event (artwork, dish, person) and, for a historic
      # place, the period it speaks of.
      add :kind, :string
      add :era, :string
    end
  end
end
