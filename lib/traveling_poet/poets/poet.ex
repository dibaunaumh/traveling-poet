defmodule TravelingPoet.Poets.Poet do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(provisioning active paused error)

  schema "poets" do
    field :name, :string
    field :slug, :string
    field :avatar_url, :string
    field :personality, :string
    field :interests, {:array, :string}, default: []
    # %{"items" => [%{"title" => ..., "author" => ...}]}
    field :currently_reading, :map, default: %{}
    field :is_public, :boolean, default: false
    field :current_lat, :float
    field :current_lng, :float
    field :current_place_name, :string
    field :current_country_code, :string
    field :arrived_at, :utc_datetime
    field :settings, :map, default: %{}
    field :status, :string, default: "provisioning"

    belongs_to :user, TravelingPoet.Accounts.User
    has_many :path_points, TravelingPoet.Poets.PathPoint
    has_many :itinerary_stops, TravelingPoet.Poets.ItineraryStop
    has_many :journal_entries, TravelingPoet.Journal.Entry

    timestamps()
  end

  @doc false
  def changeset(poet, attrs) do
    poet
    |> cast(attrs, [
      :user_id,
      :name,
      :slug,
      :avatar_url,
      :personality,
      :interests,
      :currently_reading,
      :is_public,
      :current_lat,
      :current_lng,
      :current_place_name,
      :current_country_code,
      :arrived_at,
      :settings,
      :status
    ])
    |> validate_required([:user_id, :name])
    |> put_slug()
    |> validate_required([:slug])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:slug)
    |> unique_constraint(:user_id)
  end

  defp put_slug(changeset) do
    case {get_field(changeset, :slug), get_change(changeset, :name)} do
      {nil, name} when is_binary(name) ->
        put_change(changeset, :slug, slugify(name))

      _ ->
        changeset
    end
  end

  def slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc "Days the poet has spent at the current location."
  def days_at_location(%__MODULE__{arrived_at: nil}), do: 0

  def days_at_location(%__MODULE__{arrived_at: arrived_at}) do
    DateTime.diff(DateTime.utc_now(), arrived_at, :day)
  end

  def stay_duration_days(%__MODULE__{settings: settings}) do
    Map.get(settings || %{}, "stay_duration_days", 3)
  end

  @doc """
  The poet's mission mode: "wander" (free roaming, the default) or "scout" —
  pre-visiting the user's planned itinerary.
  """
  def mode(%__MODULE__{settings: settings}) do
    case Map.get(settings || %{}, "mode") do
      "scout" -> "scout"
      _ -> "wander"
    end
  end
end
