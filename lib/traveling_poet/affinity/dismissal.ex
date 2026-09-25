defmodule TravelingPoet.Affinity.Dismissal do
  @moduledoc """
  A subject the reader took off their taste profile ("not really me"). Sticky:
  however much the signals say otherwise, it stays off until they restore it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "subject_dismissals" do
    field :path, :string
    belongs_to :user, TravelingPoet.Accounts.User
    timestamps()
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:user_id, :path])
    |> validate_required([:user_id, :path])
    |> unique_constraint([:user_id, :path])
  end
end
