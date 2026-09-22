defmodule TravelingPoet.Repo.Migrations.AddAiConsentAtToUsers do
  use Ecto.Migration

  # When the reader agreed, inside the iOS app, to what they tell their poet
  # being sent to third-party AI models (App Store guideline 5.1.2(i)).
  def change do
    alter table(:users) do
      add :ai_consent_at, :utc_datetime
    end
  end
end
