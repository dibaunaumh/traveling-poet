defmodule TravelingPoet.Usage.UsageEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(daily_run daily_run_attempt first_entry_attempt chat_turn image_gen exec tokens)

  schema "usage_events" do
    field :kind, :string
    field :tokens_in, :integer
    field :tokens_out, :integer
    field :cost_cents_est, :integer, default: 0
    field :metadata, :map, default: %{}
    field :occurred_at, :utc_datetime

    belongs_to :user, TravelingPoet.Accounts.User

    timestamps()
  end

  def kinds, do: @kinds

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :user_id,
      :kind,
      :tokens_in,
      :tokens_out,
      :cost_cents_est,
      :metadata,
      :occurred_at
    ])
    |> validate_required([:user_id, :kind, :occurred_at])
    |> validate_inclusion(:kind, @kinds)
  end
end
