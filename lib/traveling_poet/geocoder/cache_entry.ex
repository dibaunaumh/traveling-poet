defmodule TravelingPoet.Geocoder.CacheEntry do
  @moduledoc """
  One remembered Nominatim answer, hit or miss.

  Misses are cached deliberately. OSM allows the whole app one request a
  second; without a negative cache, a single address it has never heard of
  costs a request every time the poet re-sends its list -- forever.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "geocode_cache" do
    field :query_hash, :string
    field :query, :string
    field :lat, :float
    field :lng, :float
    field :place_name, :string
    field :country_code, :string
    field :city, :string
    field :country, :string
    field :found, :boolean, default: false
    field :looked_up_at, :utc_datetime

    timestamps()
  end

  @doc "Stable key for a free-text query — case and spacing must not miss."
  def hash(query) do
    query
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :query_hash,
      :query,
      :lat,
      :lng,
      :place_name,
      :country_code,
      :city,
      :country,
      :found,
      :looked_up_at
    ])
    |> validate_required([:query_hash, :query, :found, :looked_up_at])
    |> unique_constraint(:query_hash)
  end
end
