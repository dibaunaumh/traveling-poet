defmodule TravelingPoet.Repo.Migrations.CreatePoetTopics do
  use Ecto.Migration

  def change do
    create table(:poet_topics) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :label, :string, null: false
      add :kind, :string
      add :status, :string, null: false, default: "proposed"
      add :source, :string, null: false, default: "settings"
      add :every_days, :integer, null: false, default: 7
      add :position, :integer, null: false, default: 0
      add :evidence, :map, null: false, default: %{}
      timestamps()
    end

    create unique_index(:poet_topics, [:poet_id, :key])
    create index(:poet_topics, [:poet_id, :status])
  end
end
