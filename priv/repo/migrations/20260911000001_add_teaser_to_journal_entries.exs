defmodule TravelingPoet.Repo.Migrations.AddTeaserToJournalEntries do
  use Ecto.Migration

  # One line the poet writes to make its reader open the entry; the app
  # prefixes the journey day and sends it as the notification text.
  def change do
    alter table(:journal_entries) do
      add :teaser, :string
    end
  end
end
