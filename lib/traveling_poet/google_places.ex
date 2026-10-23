defmodule TravelingPoet.GooglePlaces do
  @moduledoc """
  Google's place id for the places the poets write about (dec-012), so
  "Save to Google Maps" can open them in the Google Maps app as one list
  the reader saves with Select all, then Save. Google lets no app write a
  reader's lists; a shortlist link of place ids (`MapsLinks.shortlist_urls/1`)
  is the closest it allows, and it needs the ids.

  One Places API (New) Text Search per place, asking for the id and nothing
  else (`X-Goog-FieldMask: places.id`): the "Text Search Essentials (IDs
  Only)" SKU, which Google does not charge for. The search is held to a box
  reaching about 800 m from our own coordinates: at two km, "Szara Kazimierz"
  came back as Szara's other restaurant on the main square, 1.3 km away. A
  place Google does not find there gets no id and is left out of the link: a
  wrong place is worse than a missing one.

  Ids are cached in `google_place_ids` by `key/1` (name and where, not place
  row: places are re-inserted on every re-put and bookmarks are snapshots).
  A miss is cached too and asked again after two weeks. Without
  `GOOGLE_MAPS_API_KEY` nothing is looked up and the cache is all there is.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.Repo

  @search_url "https://places.googleapis.com/v1/places:searchText"
  @retry_days 14
  # Half the box's side, in degrees of latitude (about 780 m).
  @half_box 0.007
  @concurrency 6

  defmodule Entry do
    @moduledoc false
    use Ecto.Schema

    schema "google_place_ids" do
      field :key, :string
      field :place_id, :string
      timestamps()
    end
  end

  @doc "True when a key is configured, so ids can be looked up."
  def enabled?, do: present?(api_key())

  @doc """
  The cache key for a place: its name, lowercased, at its coordinates to
  three decimals (about 100 m). Nil for a place with no coordinates: without
  them the search cannot be held to the right town.
  """
  def key(%{name: name, lat: lat, lng: lng})
      when is_binary(name) and is_number(lat) and is_number(lng) do
    case normalize(name) do
      "" ->
        nil

      n ->
        "#{n}@#{:erlang.float_to_binary(lat / 1, decimals: 3)},#{:erlang.float_to_binary(lng / 1, decimals: 3)}"
    end
  end

  def key(_), do: nil

  @doc "`%{key => place_id}` for the places already looked up and found."
  def cached(places) do
    keys = places |> Enum.map(&key/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if keys == [] do
      %{}
    else
      from(e in Entry,
        where: e.key in ^keys and not is_nil(e.place_id),
        select: {e.key, e.place_id}
      )
      |> Repo.all()
      |> Map.new()
    end
  end

  @doc """
  The places not looked up yet, or not found more than #{@retry_days} days ago.
  One per key.
  """
  def missing(places) do
    keyed =
      places
      |> Enum.map(&{key(&1), &1})
      |> Enum.reject(&is_nil(elem(&1, 0)))
      |> Enum.uniq_by(&elem(&1, 0))

    keys = Enum.map(keyed, &elem(&1, 0))
    retry_before = NaiveDateTime.add(NaiveDateTime.utc_now(), -@retry_days * 86_400)

    settled =
      if keys == [] do
        MapSet.new()
      else
        from(e in Entry,
          where: e.key in ^keys and (not is_nil(e.place_id) or e.updated_at > ^retry_before),
          select: e.key
        )
        |> Repo.all()
        |> MapSet.new()
      end

    for {k, place} <- keyed, not MapSet.member?(settled, k), do: place
  end

  @doc """
  Looks up the missing places (a few at a time), caches what Google says,
  and returns `cached/1` for all of them. Without a key, only the cache.
  """
  def resolve(places) do
    if enabled?() do
      places
      |> missing()
      |> Task.async_stream(&lookup/1,
        max_concurrency: @concurrency,
        timeout: 15_000,
        on_timeout: :kill_task
      )
      |> Enum.each(fn
        {:ok, {:ok, key, place_id}} -> store(key, place_id)
        _ -> :ok
      end)
    end

    cached(places)
  end

  @doc """
  The ids of these places in order, once each, skipping the ones without.
  """
  def ids_for(places, ids) do
    places
    |> Enum.map(&Map.get(ids, key(&1)))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp lookup(place) do
    key = key(place)

    options =
      [
        json: %{
          textQuery: query(place),
          pageSize: 1,
          locationRestriction: %{rectangle: box(place.lat, place.lng)}
        },
        headers: [{"x-goog-api-key", api_key()}, {"x-goog-fieldmask", "places.id"}],
        receive_timeout: 10_000,
        retry: false
      ] ++ Application.get_env(:traveling_poet, :google_places_req_options, [])

    case Req.post(@search_url, options) do
      {:ok, %{status: 200, body: %{"places" => [%{"id" => id} | _]}}} when is_binary(id) ->
        {:ok, key, id}

      {:ok, %{status: 200}} ->
        {:ok, key, nil}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("GooglePlaces: search returned #{status}: #{inspect(body, limit: 200)}")
        :error

      {:error, reason} ->
        Logger.warning("GooglePlaces: search failed: #{inspect(reason)}")
        :error
    end
  end

  # The name with the address the poet gave, when it gave one: the box does
  # the rest.
  defp query(place) do
    address = Map.get(place, :address)
    if present?(address), do: "#{place.name}, #{address}", else: place.name
  end

  defp box(lat, lng) do
    half_lng = @half_box / max(:math.cos(lat * :math.pi() / 180), 0.2)

    %{
      low: %{latitude: max(lat - @half_box, -90.0), longitude: max(lng - half_lng, -180.0)},
      high: %{latitude: min(lat + @half_box, 90.0), longitude: min(lng + half_lng, 180.0)}
    }
  end

  defp store(key, place_id) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert_all(
      Entry,
      [%{key: key, place_id: place_id, inserted_at: now, updated_at: now}],
      on_conflict: {:replace, [:place_id, :updated_at]},
      conflict_target: :key
    )
  end

  defp normalize(name), do: name |> String.downcase() |> String.split() |> Enum.join(" ")

  defp api_key, do: Application.get_env(:traveling_poet, :google_maps_api_key)

  defp present?(v), do: is_binary(v) and String.trim(v) != ""
end
