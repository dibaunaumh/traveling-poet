defmodule TravelingPoet.Repo.Migrations.CreateStayAreas do
  use Ecto.Migration

  def change do
    create table(:stay_areas) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :journal_entry_id, references(:journal_entries, on_delete: :delete_all), null: false
      add :city, :string, null: false
      add :name, :string, null: false
      add :summary, :text
      add :best_for, :text
      add :tradeoffs, :text
      add :recommended, :boolean, null: false, default: false
      add :lat, :float
      add :lng, :float
      add :geocode_status, :string, null: false, default: "pending"
      add :position, :integer, null: false, default: 0
      timestamps()
    end

    create index(:stay_areas, [:journal_entry_id])
    create index(:stay_areas, [:poet_id, :city])
  end
end
