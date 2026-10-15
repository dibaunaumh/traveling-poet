defmodule TravelingPoet.Repo.Migrations.CreateSpaces do
  use Ecto.Migration

  def change do
    create table(:reference_systems) do
      add :key, :string, null: false
      add :name, :string, null: false
      add :type, :string, null: false
      add :config, :map, null: false, default: %{}
      timestamps()
    end

    create unique_index(:reference_systems, [:key])

    create table(:items) do
      add :kind, :string, null: false
      add :subkind, :string
      add :name, :string, null: false
      add :norm_name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"
      add :merged_into_id, references(:items, on_delete: :nilify_all)
      add :parent_id, references(:items, on_delete: :nilify_all)
      add :city, :string
      add :summary, :text
      add :lat, :float
      add :lng, :float
      add :geocode_status, :string, null: false, default: "pending"
      add :time_start, :date
      add :time_end, :date
      add :era, :string
      add :topic, :string
      add :second_topic, :string
      add :topics_classified_at, :utc_datetime
      add :source_url, :string
      # the source URL as a matching key (Spaces.Resolver.url_key/1)
      add :url_key, :string
      add :first_poet_id, references(:poets, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:items, [:slug])
    create index(:items, [:kind, :norm_name])
    create index(:items, [:parent_id])
    create index(:items, [:topic])
    create index(:items, [:url_key])

    create table(:links) do
      add :from_item_id, references(:items, on_delete: :delete_all), null: false
      add :to_item_id, references(:items, on_delete: :delete_all), null: false
      add :relation, :string, null: false
      add :source, :string, null: false, default: "app"
      add :journal_entry_id, references(:journal_entries, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:links, [:from_item_id, :to_item_id, :relation])
    create index(:links, [:to_item_id])

    create table(:item_reviews) do
      add :item_id, references(:items, on_delete: :delete_all), null: false
      add :candidate_id, references(:items, on_delete: :delete_all), null: false
      add :reason, :string, null: false
      add :status, :string, null: false, default: "open"
      timestamps()
    end

    create index(:item_reviews, [:status])

    alter table(:places) do
      add :item_id, references(:items, on_delete: :nilify_all)
    end

    alter table(:entry_finds) do
      add :item_id, references(:items, on_delete: :nilify_all)
    end

    alter table(:stay_areas) do
      add :item_id, references(:items, on_delete: :nilify_all)
    end

    alter table(:path_points) do
      add :item_id, references(:items, on_delete: :nilify_all)
    end

    create index(:places, [:item_id])
    create index(:entry_finds, [:item_id])
    create index(:stay_areas, [:item_id])
    create index(:path_points, [:item_id])

    # The travel deployment's three reference systems. Seeded here rather
    # than at boot so a fresh database has them before anything resolves.
    for {key, name, type} <- [
          {"geo", "Geography", "metric"},
          {"subject", "Subject tree", "tree"},
          {"time", "Time", "time"}
        ] do
      execute(
        "INSERT OR IGNORE INTO reference_systems (key, name, type, config, inserted_at, updated_at) " <>
          "VALUES ('#{key}', '#{name}', '#{type}', '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)",
        "DELETE FROM reference_systems WHERE key = '#{key}'"
      )
    end
  end
end
