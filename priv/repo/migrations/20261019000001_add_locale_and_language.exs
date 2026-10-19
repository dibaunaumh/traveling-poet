defmodule TravelingPoet.Repo.Migrations.AddLocaleAndLanguage do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # The reader's interface and the poet's writing language (card-101)
      add :locale, :string, null: false, default: "en"
    end

    alter table(:journal_entries) do
      # The language this page is written in, stamped at upsert from the
      # owner's locale, so a page keeps its direction after a switch
      add :language, :string, null: false, default: "en"
    end
  end
end
