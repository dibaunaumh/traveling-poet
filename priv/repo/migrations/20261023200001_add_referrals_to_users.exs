defmodule TravelingPoet.Repo.Migrations.AddReferralsToUsers do
  use Ecto.Migration

  def change do
    # Referral credits (card-126, dec-015). A reader's invite code is made the
    # first time they look for it; the friend it brought in points back at
    # them. Deleting the referrer leaves the friend's account alone.
    alter table(:users) do
      add :referral_code, :string
      add :referred_by_id, references(:users, on_delete: :nilify_all)
      add :invite_prompt_dismissed_at, :utc_datetime
    end

    create unique_index(:users, [:referral_code])
    create index(:users, [:referred_by_id])
  end
end
