defmodule TravelingPoet.Repo.Migrations.CreateCreditTransactions do
  use Ecto.Migration

  # Grandfather grant for everyone who signed up before credits existed.
  @grandfather_millicredits 30_000

  def up do
    create table(:credit_transactions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      # Signed milli-credits (1 credit = 1000). Positive = grant/purchase,
      # negative = debit.
      add :amount, :integer, null: false
      add :kind, :string, null: false
      add :balance_after, :integer, null: false
      # Idempotency key: Stripe session id, usage_event id, "signup:<id>"…
      add :reference, :string
      add :metadata, :map, default: %{}
      timestamps()
    end

    create index(:credit_transactions, [:user_id, :inserted_at])

    create unique_index(:credit_transactions, [:kind, :reference], where: "reference IS NOT NULL")

    alter table(:users) do
      # Cached balance; the ledger (sum of amounts) is authoritative.
      add :credits_balance, :integer, default: 0, null: false
      add :low_credits_notified_at, :utc_datetime
    end

    # Data step in plain SQL so it never depends on app code.
    execute """
    INSERT INTO credit_transactions
      (user_id, amount, kind, balance_after, reference, metadata, inserted_at, updated_at)
    SELECT id, #{@grandfather_millicredits}, 'grant_grandfather', #{@grandfather_millicredits},
           'grandfather:' || id, '{}', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM users
    """

    execute "UPDATE users SET credits_balance = #{@grandfather_millicredits}"
  end

  def down do
    alter table(:users) do
      remove :credits_balance
      remove :low_credits_notified_at
    end

    drop table(:credit_transactions)
  end
end
