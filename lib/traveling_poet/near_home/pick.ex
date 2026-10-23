defmodule TravelingPoet.NearHome.Pick do
  @moduledoc """
  One thing the poet found near the reader's home for the week (card-71): an
  event, an exhibition, a market, a performance, a place or an outing, with
  when, where, how far from home, the page it was read on, and why it fits
  this reader. Written only through `NearHome.ingest/4`, which checks the
  link, the dates and the distance.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(event exhibition market performance place outing other)

  schema "near_home_picks" do
    field :week_of, :date
    field :name, :string
    field :kind, :string, default: "other"
    field :starts_on, :date
    field :ends_on, :date
    field :when_text, :string
    field :place_name, :string
    field :address, :string
    field :lat, :float
    field :lng, :float
    field :distance_km, :float
    field :url, :string
    field :blurb, :string
    field :position, :integer, default: 0

    belongs_to :user, TravelingPoet.Accounts.User
    belongs_to :poet, TravelingPoet.Poets.Poet

    timestamps()
  end

  def kinds, do: @kinds

  @doc "A kind the model made up becomes \"other\" rather than failing the pick."
  def normalize_kind(kind) when is_binary(kind) do
    kind = kind |> String.trim() |> String.downcase()
    if kind in @kinds, do: kind, else: "other"
  end

  def normalize_kind(_), do: "other"

  @fields ~w(user_id poet_id week_of name kind starts_on ends_on when_text place_name address
             lat lng distance_km url blurb position)a

  def changeset(pick, attrs) do
    pick
    |> cast(attrs, @fields)
    |> validate_required([:user_id, :poet_id, :week_of, :name, :url])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:name, max: 200)
    |> validate_length(:when_text, max: 120)
  end
end
