defmodule TravelingPoet.Repo.Migrations.CreateNearHomePicks do
  use Ecto.Migration

  def change do
    # "Near you" (card-71): once a week the poet looks for events and finds
    # near the reader's home. Private by nature (it shows where they live),
    # so it hangs off the user and never off the public journal.
    create table(:near_home_picks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :poet_id, references(:poets, on_delete: :delete_all), null: false
      # the day the batch was delivered
      add :week_of, :date, null: false
      add :name, :string, null: false
      add :kind, :string, null: false, default: "other"
      add :starts_on, :date
      add :ends_on, :date
      add :when_text, :string
      add :place_name, :string
      add :address, :string
      add :lat, :float
      add :lng, :float
      add :distance_km, :float
      add :url, :text, null: false
      add :blurb, :text
      add :position, :integer, null: false, default: 0
      timestamps()
    end

    create index(:near_home_picks, [:user_id, :week_of])

    alter table(:users) do
      add :near_home, :boolean, null: false, default: true
    end
  end
end
