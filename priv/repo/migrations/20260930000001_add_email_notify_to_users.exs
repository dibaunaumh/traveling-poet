defmodule TravelingPoet.Repo.Migrations.AddEmailNotifyToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :email_notify, :boolean, null: false, default: true
    end
  end
end
