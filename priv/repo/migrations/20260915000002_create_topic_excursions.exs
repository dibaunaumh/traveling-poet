defmodule TravelingPoet.Repo.Migrations.CreateTopicExcursions do
  use Ecto.Migration

  # An excursion is queue AND log in one row: a chat request exists before any
  # entry does, so it cannot hang off journal_entries; once written, the same
  # row links the entry back. Entries stay untouched, as with entry_prompts.
  def change do
    create table(:topic_excursions) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :topic_id, references(:poet_topics, on_delete: :delete_all), null: false
      add :journal_entry_id, references(:journal_entries, on_delete: :nilify_all)
      add :status, :string, null: false, default: "queued"
      add :source, :string, null: false, default: "app"
      add :requested_venue, :string
      add :requested_url, :string
      # The entry's date once written; what the cadence and the "never two in
      # a row" rule read, so both stay plain date queries.
      add :scheduled_for, :date
      add :venue_name, :string
      add :venue_url, :string
      timestamps()
    end

    create unique_index(:topic_excursions, [:journal_entry_id])
    create index(:topic_excursions, [:poet_id, :status])
    create index(:topic_excursions, [:poet_id, :scheduled_for])
  end
end
