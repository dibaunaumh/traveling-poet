defmodule TravelingPoet.Poets do
  @moduledoc """
  The Poets context: poet profiles + journey path.
  """

  import Ecto.Query
  alias TravelingPoet.Repo
  alias TravelingPoet.Poets.{Poet, PathPoint}

  def get_poet!(id), do: Repo.get!(Poet, id)
  def get_poet(id), do: Repo.get(Poet, id)
  def get_poet_by_user(user_id), do: Repo.get_by(Poet, user_id: user_id)
  def get_public_poet_by_slug(slug), do: Repo.get_by(Poet, slug: slug, is_public: true)

  def list_public_poets do
    Poet
    |> where(is_public: true, status: "active")
    |> where([p], not is_nil(p.current_lat))
    |> Repo.all()
  end

  def create_poet(attrs) do
    case %Poet{} |> Poet.changeset(attrs) |> Repo.insert() do
      {:error, %{errors: errors} = changeset} ->
        # slug collision → retry with numeric suffixes
        if Keyword.has_key?(errors, :slug) do
          retry_with_suffixed_slug(attrs, changeset)
        else
          {:error, changeset}
        end

      ok ->
        ok
    end
  end

  defp retry_with_suffixed_slug(attrs, original_changeset) do
    base = Poet.slugify(attrs[:name] || attrs["name"] || "poet")

    Enum.reduce_while(2..99, {:error, original_changeset}, fn n, acc ->
      attrs = Map.put(attrs, slug_key(attrs), "#{base}-#{n}")

      case %Poet{} |> Poet.changeset(attrs) |> Repo.insert() do
        {:ok, poet} ->
          {:halt, {:ok, poet}}

        {:error, %{errors: errors}} = err ->
          if Keyword.has_key?(errors, :slug), do: {:cont, acc}, else: {:halt, err}
      end
    end)
  end

  defp slug_key(attrs) when is_map(attrs) do
    if Enum.any?(Map.keys(attrs), &is_binary/1), do: "slug", else: :slug
  end

  def update_poet(%Poet{} = poet, attrs) do
    poet
    |> Poet.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Moves the poet to a new location: closes the current path point (sets
  `departed_at`), appends the next one, and updates the poet's denormalized
  `current_*` fields. Runs in a transaction.
  """
  def move_to(%Poet{} = poet, %{lat: lat, lng: lng} = attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      current = current_path_point(poet.id)

      if current do
        current
        |> PathPoint.changeset(%{departed_at: now})
        |> Repo.update!()
      end

      position = if current, do: current.position + 1, else: 0

      %PathPoint{}
      |> PathPoint.changeset(%{
        poet_id: poet.id,
        lat: lat,
        lng: lng,
        place_name: attrs[:place_name],
        country_code: attrs[:country_code],
        arrived_at: now,
        position: position
      })
      |> Repo.insert!()

      poet
      |> Poet.changeset(%{
        current_lat: lat,
        current_lng: lng,
        current_place_name: attrs[:place_name],
        current_country_code: attrs[:country_code],
        arrived_at: now
      })
      |> Repo.update!()
    end)
  end

  def current_path_point(poet_id) do
    PathPoint
    |> where(poet_id: ^poet_id)
    |> where([p], is_nil(p.departed_at))
    |> order_by(desc: :position)
    |> limit(1)
    |> Repo.one()
  end

  def list_path_points(poet_id) do
    PathPoint
    |> where(poet_id: ^poet_id)
    |> order_by(asc: :position)
    |> Repo.all()
  end
end
