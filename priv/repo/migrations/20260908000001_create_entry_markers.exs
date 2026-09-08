defmodule TravelingPoet.Repo.Migrations.CreateEntryMarkers do
  use Ecto.Migration

  # A marker is a reader's note on one passage of an entry: "boring", "draw
  # this", "link needed". Its own table, anchored to the ENTRY and a quoted
  # snippet rather than to a section row: `Journal.replace_sections/2` wipes
  # and re-inserts sections on every agent re-put (the same reason
  # entry_prompts and places are separate), so a section FK would lose every
  # marker the moment the poet revised the entry in response to them.
  def change do
    create table(:entry_markers) do
      add :journal_entry_id, references(:journal_entries, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      # text | section | illustration
      add :target, :string, null: false
      # nil for an illustration no section references
      add :section_kind, :string
      add :section_position, :integer
      # illustration targets only; plain integer like journal_sections.media_id
      add :media_id, :integer
      # the marked text, plus a little context either side to re-find it
      add :quote, :text
      add :prefix, :string
      add :suffix, :string
      # stamped when the digest went to the poet
      add :sent_at, :utc_datetime

      timestamps()
    end

    create index(:entry_markers, [:journal_entry_id])
    create index(:entry_markers, [:sent_at])
  end
end
