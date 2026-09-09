defmodule TravelingPoet.Repo.Migrations.AddNoteToEntryMarkers do
  use Ecto.Migration

  # The "Other feedback" marker carries the reader's own words about the
  # passage; every other kind says everything by its name.
  def change do
    alter table(:entry_markers) do
      add :note, :text
    end
  end
end
