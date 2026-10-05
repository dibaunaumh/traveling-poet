defmodule TravelingPoet.Repo.Migrations.AddHoursToPlaces do
  use Ecto.Migration

  def change do
    alter table(:places) do
      add :hours, :string
      add :book_ahead, :boolean, null: false, default: false
    end
  end
end
