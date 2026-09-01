defmodule TravelingPoet.Repo.Migrations.AddPlaceEventDates do
  use Ecto.Migration

  # An event without dates is worse than no event: the guide would go on
  # recommending an exhibition months after it closed, and the reader has no
  # way to tell. Nullable because only events have them.
  def change do
    alter table(:places) do
      add :starts_on, :date
      add :ends_on, :date
    end

    create index(:places, [:ends_on])
  end
end
