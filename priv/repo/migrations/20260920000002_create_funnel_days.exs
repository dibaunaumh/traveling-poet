defmodule TravelingPoet.Repo.Migrations.CreateFunnelDays do
  use Ecto.Migration

  # Daily funnel numbers, one row per UTC day and traffic source ("all", or a
  # utm_source/ref value). Aggregates only: no visitor ids, no user ids. This
  # is what the change stream carries about visits; the raw visit_events stay
  # in this database. Rows outlive the raw events' 180-day retention.
  def change do
    create table(:funnel_days) do
      add :day, :date, null: false
      add :source, :string, null: false
      add :visitors, :integer, null: false, default: 0
      add :engaged, :integer, null: false, default: 0
      add :cta_visitors, :integer, null: false, default: 0
      add :bounced, :integer, null: false, default: 0
      add :median_visible_s, :integer
      add :signups, :integer, null: false, default: 0
      add :onboarding_poet, :integer, null: false, default: 0
      add :onboarding_journey, :integer, null: false, default: 0
      add :onboarding_send_off, :integer, null: false, default: 0
      add :onboarding_done, :integer, null: false, default: 0
      add :first_entries, :integer, null: false, default: 0
      add :returned, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:funnel_days, [:day, :source])
  end
end
