defmodule TravelingPoet.Analytics.VisitEvent do
  @moduledoc "One thing a visitor did. See `TravelingPoet.Analytics`."
  use Ecto.Schema
  import Ecto.Changeset

  @names ~w(pageview engage click signup login)
  @strings [:path, :target, :referrer_host, :utm_source, :utm_campaign]

  schema "visit_events" do
    field :visitor, :string
    field :name, :string
    field :path, :string
    field :target, :string
    field :referrer_host, :string
    field :utm_source, :string
    field :utm_campaign, :string
    field :duration_ms, :integer
    field :scroll_pct, :integer
    field :viewport, :string

    belongs_to :user, TravelingPoet.Accounts.User

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def names, do: @names

  @doc false
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:visitor, :name, :viewport, :duration_ms, :scroll_pct, :user_id | @strings])
    |> update_change(:path, &truncate(&1, 200))
    |> update_change(:target, &truncate(&1, 60))
    |> update_change(:referrer_host, &truncate(&1, 100))
    |> update_change(:utm_source, &truncate(&1, 60))
    |> update_change(:utm_campaign, &truncate(&1, 60))
    |> validate_required([:visitor, :name])
    |> validate_inclusion(:name, @names)
    |> validate_inclusion(:viewport, ~w(mobile desktop))
    # A day of visible time is the most one page view can honestly claim.
    |> validate_number(:duration_ms, greater_than_or_equal_to: 0, less_than: 86_400_000)
    |> validate_number(:scroll_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end

  defp truncate(s, max) when is_binary(s), do: String.slice(s, 0, max)
  defp truncate(s, _max), do: s
end
