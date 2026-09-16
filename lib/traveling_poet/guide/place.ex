defmodule TravelingPoet.Guide.Place do
  @moduledoc """
  A concrete, named place the poet found and would send its companion to.

  The rating is the POET's own, 1-5, and the UI is required to render it
  attributed ("Wren's pick"). It is not a review score and must never be shown
  as one -- hence the field name.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(restaurant cafe viewpoint attraction event landmark shop)
  @geocode_statuses ~w(pending ok failed)

  schema "places" do
    field :entry_date, :date
    field :name, :string
    field :category, :string
    field :blurb, :string
    field :address, :string
    field :lat, :float
    field :lng, :float
    field :geocode_status, :string, default: "pending"
    field :poet_rating, :integer
    field :source_url, :string
    field :media_id, :id
    # Events only: what the entry said about when it runs.
    field :starts_on, :date
    field :ends_on, :date
    field :position, :integer, default: 0
    field :source, :string, default: "agent"

    belongs_to :poet, TravelingPoet.Poets.Poet
    belongs_to :journal_entry, TravelingPoet.Journal.Entry
    belongs_to :path_point, TravelingPoet.Poets.PathPoint

    timestamps()
  end

  def categories, do: @categories

  @doc """
  Which filter chip a category falls under. One function so the chips, the map
  pins and the counts can never disagree.
  """
  def group_for(category) when category in ~w(restaurant cafe), do: "food"
  def group_for("event"), do: "events"
  def group_for(_), do: "sights"

  @doc """
  Coerces whatever the model sent into a known category. An unrecognised value
  becomes "attraction" rather than failing the write -- same posture as
  maybe_attach_prompt/2 in JournalApiController: a fumbled field must never
  cost the poet the rest of its list.
  """
  def normalize_category(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()
    if normalized in @categories, do: normalized, else: "attraction"
  end

  def normalize_category(_), do: "attraction"

  @doc """
  Has this event finished, as of `today`?

  Only ever true for a place with an `ends_on`, so a venue is never "ended".
  """
  def ended?(%__MODULE__{ends_on: nil}, _today), do: false
  def ended?(%__MODULE__{ends_on: ends_on}, today), do: Date.compare(ends_on, today) == :lt

  @doc "A human date range, or nil when the entry gave no dates."
  def date_range(%__MODULE__{starts_on: nil, ends_on: nil}), do: nil

  def date_range(%__MODULE__{starts_on: nil, ends_on: ends_on}),
    do: "until " <> fmt(ends_on)

  def date_range(%__MODULE__{starts_on: starts_on, ends_on: nil}),
    do: "from " <> fmt(starts_on)

  def date_range(%__MODULE__{starts_on: same, ends_on: same}), do: fmt(same)

  def date_range(%__MODULE__{starts_on: starts_on, ends_on: ends_on}),
    do: fmt(starts_on) <> " – " <> fmt(ends_on)

  defp fmt(date), do: Calendar.strftime(date, "%b %-d")

  @doc "Is this place placeable on the map?"
  def mapped?(%__MODULE__{lat: lat, lng: lng}), do: is_number(lat) and is_number(lng)

  @doc false
  def changeset(place, attrs) do
    place
    |> cast(attrs, [
      :poet_id,
      :journal_entry_id,
      :path_point_id,
      :entry_date,
      :name,
      :category,
      :blurb,
      :address,
      :lat,
      :lng,
      :geocode_status,
      :poet_rating,
      :source_url,
      :media_id,
      :position,
      :source,
      :starts_on,
      :ends_on
    ])
    |> update_change(:category, &normalize_category/1)
    |> update_change(:name, &String.trim/1)
    |> update_change(:blurb, &TravelingPoet.Journal.Blank.clean/1)
    |> validate_required([:poet_id, :journal_entry_id, :entry_date, :name, :category, :position])
    |> validate_inclusion(:category, @categories)
    |> validate_inclusion(:geocode_status, @geocode_statuses)
    |> validate_number(:poet_rating, greater_than_or_equal_to: 1, less_than_or_equal_to: 5)
    |> validate_number(:lat, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:lng, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> unique_constraint([:journal_entry_id, :name])
  end
end
