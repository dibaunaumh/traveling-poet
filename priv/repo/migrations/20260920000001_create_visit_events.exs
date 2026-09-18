defmodule TravelingPoet.Repo.Migrations.CreateVisitEvents do
  use Ecto.Migration

  # First-party visit counting. No cookie: `visitor` is a hash of IP + user
  # agent salted per day, so it cannot be reversed or followed across days.
  # user_id is set only on the sign-up/sign-in row, which is the join from an
  # anonymous visit to an account.
  def change do
    create table(:visit_events) do
      add :visitor, :string, null: false
      # pageview | engage | click | signup | login
      add :name, :string, null: false
      add :path, :string
      # the data-track label of what was clicked
      add :target, :string
      add :referrer_host, :string
      add :utm_source, :string
      add :utm_campaign, :string
      # engage only: visible time on the page and how far down it was read
      add :duration_ms, :integer
      add :scroll_pct, :integer
      # mobile | desktop
      add :viewport, :string
      add :user_id, references(:users, on_delete: :delete_all)

      timestamps(updated_at: false, type: :utc_datetime)
    end

    create index(:visit_events, [:inserted_at, :name])
    create index(:visit_events, [:visitor])
    create index(:visit_events, [:user_id])
  end
end
