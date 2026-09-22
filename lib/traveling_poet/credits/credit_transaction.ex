defmodule TravelingPoet.Credits.CreditTransaction do
  @moduledoc """
  One signed movement on a user's credit ledger. Amounts are milli-credits
  (1 credit = 1000) so a future metered debit doesn't need a migration.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(grant_signup grant_referral grant_grandfather grant_admin purchase purchase_refund debit_daily_run debit_book_compose refund admin_adjust)

  schema "credit_transactions" do
    field :amount, :integer
    field :kind, :string
    field :balance_after, :integer
    field :reference, :string
    field :metadata, :map, default: %{}

    belongs_to :user, TravelingPoet.Accounts.User

    timestamps()
  end

  def kinds, do: @kinds

  @doc false
  def changeset(tx, attrs) do
    tx
    |> cast(attrs, [:user_id, :amount, :kind, :balance_after, :reference, :metadata])
    |> validate_required([:user_id, :amount, :kind, :balance_after])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint([:kind, :reference], name: :credit_transactions_kind_reference_index)
  end
end
