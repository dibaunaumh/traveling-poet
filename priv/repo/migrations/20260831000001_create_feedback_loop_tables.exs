defmodule TravelingPoet.Repo.Migrations.CreateFeedbackLoopTables do
  use Ecto.Migration

  def change do
    # What the poet has learned about its companion. One row per distinct
    # preference; polarity deliberately stays OUT of the key so "more museums"
    # and "fewer museums" collide and resolve in place rather than accumulating
    # as contradictory rows.
    create table(:poet_preferences) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :label, :string, null: false
      add :dimension, :string, null: false
      add :polarity, :string, null: false
      add :source, :string, null: false
      add :status, :string, null: false, default: "active"
      add :weight, :integer, null: false, default: 1
      add :evidence, :map, default: %{}
      add :last_confirmed_at, :utc_datetime

      timestamps()
    end

    create unique_index(:poet_preferences, [:poet_id, :key])
    create index(:poet_preferences, [:poet_id, :status])

    # The one-tap question under an entry. Its own table rather than a section:
    # replace_sections/2 wipes sections wholesale and the skill tells the poet
    # to re-put them after illustrating, which would destroy the answer.
    create table(:entry_prompts) do
      add :journal_entry_id, references(:journal_entries, on_delete: :delete_all), null: false
      add :question, :string, null: false
      add :options, :map, default: %{"items" => []}
      add :source, :string, null: false
      add :answered_at, :utc_datetime
      add :answer_option_id, :string
      add :dismissed_at, :utc_datetime

      timestamps()
    end

    # At most one prompt per entry, ever — this index is the cadence backstop.
    create unique_index(:entry_prompts, [:journal_entry_id])

    # Did the owner actually open this entry? Until now the app could not tell
    # a happy silent reader from someone who stopped coming back.
    alter table(:journal_entries) do
      add :owner_viewed_at, :utc_datetime
      add :owner_view_count, :integer, null: false, default: 0
    end
  end
end
