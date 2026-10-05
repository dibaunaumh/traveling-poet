defmodule TravelingPoet.Repo.Migrations.AddSavedShareTokenToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :saved_share_token, :string
    end

    create unique_index(:users, [:saved_share_token])
  end
end
