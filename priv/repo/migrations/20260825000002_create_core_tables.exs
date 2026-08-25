defmodule TravelingPoet.Repo.Migrations.CreateCoreTables do
  use Ecto.Migration

  def change do
    create table(:poets) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :avatar_url, :string
      add :personality, :text
      add :interests, {:array, :string}, default: []
      add :currently_reading, :map, default: %{}
      add :is_public, :boolean, default: false, null: false
      add :current_lat, :float
      add :current_lng, :float
      add :current_place_name, :string
      add :current_country_code, :string
      add :arrived_at, :utc_datetime
      add :settings, :map, default: %{}
      add :status, :string, default: "provisioning", null: false
      timestamps()
    end

    create unique_index(:poets, [:user_id])
    create unique_index(:poets, [:slug])
    create index(:poets, [:is_public])

    create table(:path_points) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :lat, :float, null: false
      add :lng, :float, null: false
      add :place_name, :string
      add :country_code, :string
      add :arrived_at, :utc_datetime, null: false
      add :departed_at, :utc_datetime
      add :position, :integer, null: false
      timestamps()
    end

    create index(:path_points, [:poet_id, :position])

    create table(:journal_entries) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :entry_date, :date, null: false
      add :title, :string
      add :place_name, :string
      add :lat, :float
      add :lng, :float
      add :status, :string, default: "draft", null: false
      add :published_at, :utc_datetime
      add :weather, :map, default: %{}
      add :sources, :map, default: %{}
      timestamps()
    end

    create unique_index(:journal_entries, [:poet_id, :entry_date])
    create index(:journal_entries, [:poet_id, :status])

    create table(:journal_sections) do
      add :journal_entry_id, references(:journal_entries, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :position, :integer, default: 0, null: false
      add :title, :string
      add :body, :text
      add :media_id, :integer
      add :metadata, :map, default: %{}
      timestamps()
    end

    create index(:journal_sections, [:journal_entry_id, :position])

    create table(:media) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :journal_entry_id, references(:journal_entries, on_delete: :nilify_all)
      add :s3_key, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :integer
      add :kind, :string, null: false
      add :alt_text, :string
      add :prompt, :text
      # list of %{"url" => ..., "label" => ...}: the ORIGINAL photos the
      # illustration was drawn from — rendered as outbound links, never stored
      add :sources, :map, default: %{"items" => []}
      timestamps()
    end

    create index(:media, [:poet_id])
    create index(:media, [:journal_entry_id])

    create table(:reactions) do
      add :journal_entry_id, references(:journal_entries, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :visibility, :string, null: false
      add :note, :text
      timestamps()
    end

    create unique_index(:reactions, [:journal_entry_id, :user_id, :kind, :visibility])

    create table(:chat_messages) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false
      add :content, :text, null: false
      add :response_id, :string
      add :attachments, :map, default: %{}
      add :channel, :string, default: "web", null: false
      timestamps()
    end

    create index(:chat_messages, [:user_id, :inserted_at])

    create table(:usage_events) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :tokens_in, :integer
      add :tokens_out, :integer
      add :cost_cents_est, :integer, default: 0, null: false
      add :metadata, :map, default: %{}
      add :occurred_at, :utc_datetime, null: false
      timestamps()
    end

    create index(:usage_events, [:user_id, :occurred_at])
  end
end
