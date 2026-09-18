defmodule TravelingPoet.Analytics.FunnelDay do
  @moduledoc """
  One day's funnel for one traffic source, built by `Analytics.Rollup`.
  `source` is `"all"` or a `utm_source`/`ref` value. The visit steps count
  that day's visitors; the account steps (signups down to returned) count
  the users who signed up that day, and keep moving as those users progress.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @counts [
    :visitors,
    :engaged,
    :cta_visitors,
    :bounced,
    :median_visible_s,
    :signups,
    :onboarding_poet,
    :onboarding_journey,
    :onboarding_send_off,
    :onboarding_done,
    :first_entries,
    :returned
  ]

  schema "funnel_days" do
    field :day, :date
    field :source, :string

    for f <- @counts, do: field(f, :integer, default: 0)

    timestamps(type: :utc_datetime)
  end

  def counts, do: @counts

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:day, :source | @counts])
    |> validate_required([:day, :source])
    |> unique_constraint([:day, :source])
  end
end
