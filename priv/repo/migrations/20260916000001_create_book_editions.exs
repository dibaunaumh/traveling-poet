defmodule TravelingPoet.Repo.Migrations.CreateBookEditions do
  use Ecto.Migration

  # One row per composition the companion paid for: the poet's own front and
  # back matter for the printed journal. It never touches journal tables, so
  # a composition can fail, be redone or be ignored without costing a word of
  # the journal itself. The ledger row that paid for it points back here by
  # reference ("book_compose:<id>").
  def change do
    create table(:book_editions) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "composed"
      add :status, :string, null: false, default: "composing"
      # dedication, foreword, epilogue, chapter_openers, pull_quotes
      add :matter, :map, null: false, default: %{}
      add :chapter_count, :integer, null: false, default: 0
      # milli-credits actually debited (0 for an exempt account)
      add :credits_charged, :integer, null: false, default: 0
      add :composed_at, :utc_datetime
      add :error, :string
      timestamps()
    end

    create index(:book_editions, [:poet_id, :inserted_at])
    create index(:book_editions, [:status])
  end
end
