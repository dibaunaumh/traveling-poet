defmodule TravelingPoet.Repo.Migrations.CreateApnsDevices do
  use Ecto.Migration

  # One row per iPhone or iPad that turned notifications on in the iOS app.
  # The token is Apple's address for that app install.
  def change do
    create table(:apns_devices) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :text, null: false
      # "sandbox" (a debug build) or "production": which APNs host knows it
      add :environment, :string, null: false, default: "production"
      add :last_sent_at, :utc_datetime
      add :last_error, :string

      timestamps()
    end

    create unique_index(:apns_devices, [:token])
    create index(:apns_devices, [:user_id])
  end
end
