defmodule TravelingPoet.Spaces.Item do
  @moduledoc """
  The shared, canonical thing a poet found (kb-002): one row per real place,
  event, work or idea across every poet and every day. What one poet said
  about it on one day stays on the per-poet rows (`Guide.Place`,
  `Topics.Find`, `Guide.StayArea`), which point here through `item_id` and
  are the item's visits.

  An item carries its coordinates in each reference system it has them in:
  `lat`/`lng` (geo), `topic`/`second_topic` (subject), `time_start`,
  `time_end` or `era` (time). The app fills them from the visits; the poet
  never sees an item id.

  `norm_name` is the matching key (`Guide.name_key/1`), `city` the entry's
  free-text place name until phase 1 brings a hierarchy, `parent_id` the stay
  (a city item) the thing sits in. A merged item keeps its row with
  `status: "merged"` and `merged_into_id`, so its id and slug keep resolving.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(place event artwork dish encounter person product idea work other)
  @statuses ~w(active merged retired)

  schema "items" do
    field :kind, :string
    field :subkind, :string
    field :name, :string
    field :norm_name, :string
    field :slug, :string
    field :status, :string, default: "active"
    field :city, :string
    field :summary, :string
    field :lat, :float
    field :lng, :float
    field :geocode_status, :string, default: "pending"
    field :time_start, :date
    field :time_end, :date
    field :era, :string
    field :topic, :string
    field :second_topic, :string
    field :topics_classified_at, :utc_datetime
    field :source_url, :string
    # `source_url` as a matching key (Resolver.url_key/1); kept by the changeset.
    field :url_key, :string

    belongs_to :merged_into, __MODULE__
    belongs_to :parent, __MODULE__
    belongs_to :first_poet, TravelingPoet.Poets.Poet

    timestamps()
  end

  def kinds, do: @kinds

  @doc false
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :kind,
      :subkind,
      :name,
      :slug,
      :status,
      :city,
      :summary,
      :lat,
      :lng,
      :geocode_status,
      :time_start,
      :time_end,
      :era,
      :topic,
      :second_topic,
      :topics_classified_at,
      :source_url,
      :merged_into_id,
      :parent_id,
      :first_poet_id
    ])
    |> update_change(:name, &String.trim/1)
    |> put_norm_name()
    |> put_url_key()
    |> validate_required([:kind, :name, :norm_name, :slug])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:geocode_status, ~w(pending ok failed))
    |> validate_number(:lat, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:lng, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> unique_constraint(:slug)
  end

  defp put_norm_name(changeset) do
    case get_change(changeset, :name) do
      nil -> changeset
      name -> put_change(changeset, :norm_name, TravelingPoet.Spaces.Resolver.name_key(name))
    end
  end

  defp put_url_key(changeset) do
    case get_change(changeset, :source_url) do
      nil -> changeset
      url -> put_change(changeset, :url_key, TravelingPoet.Spaces.Resolver.url_key(url))
    end
  end

  @doc "Is this item placeable on the map?"
  def mapped?(%__MODULE__{lat: lat, lng: lng}), do: is_number(lat) and is_number(lng)

  @doc """
  A URL-safe slug for an item: its normalised name, "place" when the name
  normalises to nothing. Uniqueness is the caller's (`Spaces.unique_slug/1`).
  """
  def base_slug(name) do
    case name
         |> TravelingPoet.Spaces.Resolver.name_key()
         |> String.replace(" ", "-")
         |> String.slice(0, 80) do
      "" -> "item"
      slug -> slug
    end
  end
end
