defmodule TravelingPoet.Repo.Migrations.CreateBookPdfs do
  use Ecto.Migration

  # One row per PDF of the book: which edition, which paper, how the render on
  # the poet's sprite went, and where the file is. A snapshot, like a print
  # run: the journal can grow after it without changing it.
  def change do
    create table(:book_pdfs) do
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      add :edition_id, references(:book_editions, on_delete: :nilify_all)
      add :variant, :string, null: false, default: "plain"
      add :page_size, :string, null: false, default: "a5"
      add :status, :string, null: false, default: "rendering"
      add :s3_key, :string
      add :byte_size, :integer
      add :pages, :integer
      add :error, :string
      # the tail of the render log from the sprite, for when it fails
      add :log, :text
      add :rendered_at, :utc_datetime
      timestamps()
    end

    create index(:book_pdfs, [:poet_id, :inserted_at])
    create index(:book_pdfs, [:status])
  end
end
