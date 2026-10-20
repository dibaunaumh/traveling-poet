defmodule TravelingPoet.Repo.Migrations.AddEmailFullPageToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      # The daily email carries the whole page, not only the note (card-124)
      add :email_full_page, :boolean, null: false, default: false
    end
  end
end
