defmodule TravelingPoet.Bookmarks do
  @moduledoc """
  A reader's saved places and finds (card-70), shown under Saved in their
  own guide. Saved from their own journal, any public poet's guide, or
  Discover.

  A bookmark points at the page and the item's name (see `Bookmark`), so
  the live item is looked up again whenever the list is shown; when it has
  gone from the page, the saved copy stands in. A private poet's item is
  only ever saveable by its own reader, and if a poet the reader saved from
  later turns private, their saved copy keeps no map position.
  """

  import Ecto.Query

  alias TravelingPoet.Bookmarks.Bookmark
  alias TravelingPoet.Guide.Place
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Repo
  alias TravelingPoet.Topics.Find

  @place_fields ~w(name category blurb address lat lng poet_rating source_url media_id starts_on ends_on entry_date path_point_id hours book_ahead)a
  @find_fields ~w(name url kind blurb poet_rating media_id entry_date)a

  @doc "The key a bookmark and its item share."
  def key(%Place{journal_entry_id: e, name: n}), do: {"place", e, n}
  def key(%Find{journal_entry_id: e, name: n}), do: {"find", e, n}

  @doc "Every key the reader saved, for marking Save buttons."
  def keys(nil), do: MapSet.new()

  def keys(user_id) do
    Bookmark
    |> where(user_id: ^user_id)
    |> select([b], {b.kind, b.journal_entry_id, b.name})
    |> Repo.all()
    |> MapSet.new()
  end

  def saved?(keys, item), do: MapSet.member?(keys, key(item))

  def count(user_id), do: Repo.aggregate(where(Bookmark, user_id: ^user_id), :count)

  @doc """
  Saves the place or find, or removes it when already saved. Only items the
  reader may see: their own poet's, or a public poet's published page.
  """
  def toggle(user_id, kind, id) when kind in ["place", "find"] do
    with %{} = item <- fetch(kind, id),
         true <- visible?(user_id, item) do
      {k, entry_id, name} = key(item)

      case Repo.get_by(Bookmark,
             user_id: user_id,
             kind: k,
             journal_entry_id: entry_id,
             name: name
           ) do
        nil ->
          %Bookmark{}
          |> Bookmark.changeset(%{
            user_id: user_id,
            kind: k,
            poet_id: item.poet_id,
            journal_entry_id: entry_id,
            name: name,
            snapshot: snapshot(item)
          })
          |> Repo.insert()
          |> case do
            {:ok, _} -> {:ok, :saved}
            error -> error
          end

        bookmark ->
          Repo.delete(bookmark)
          {:ok, :removed}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def toggle(_user_id, _kind, _id), do: {:error, :not_found}

  @doc "Removes one of the reader's bookmarks by its own id (a saved copy has no live item)."
  def remove(user_id, bookmark_id) do
    case Repo.get_by(Bookmark, id: bookmark_id, user_id: user_id) do
      nil -> {:error, :not_found}
      bookmark -> with({:ok, _} <- Repo.delete(bookmark), do: {:ok, :removed})
    end
  end

  @doc """
  The reader's saved items, newest first, as `%{bookmark, item, poet, live?}`
  with `item` a `%Place{}` or `%Find{}`: the live one when the page still
  has it, else one rebuilt from the saved copy (id: the bookmark's, negated,
  so it can still be selected on the map).
  """
  def list(user_id) do
    bookmarks =
      Bookmark
      |> where(user_id: ^user_id)
      |> order_by(desc: :inserted_at, desc: :id)
      |> Repo.all()

    poets =
      bookmarks
      |> Enum.map(& &1.poet_id)
      |> Enum.reject(&is_nil/1)
      |> then(&Repo.all(from p in Poet, where: p.id in ^&1))
      |> Map.new(&{&1.id, &1})

    live = live_items(bookmarks)

    Enum.map(bookmarks, fn b ->
      poet = poets[b.poet_id]
      found = live[{b.kind, b.journal_entry_id, b.name}]
      item = found || rebuilt(b)
      item = if poet && visible_poet?(user_id, poet), do: item, else: unmapped(item)
      %{bookmark: b, item: item, poet: poet, live?: found != nil}
    end)
  end

  defp live_items(bookmarks) do
    entry_ids =
      bookmarks |> Enum.map(& &1.journal_entry_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    published =
      from(e in Entry, where: e.id in ^entry_ids and e.status == "published", select: e.id)

    places = Repo.all(from p in Place, where: p.journal_entry_id in subquery(published))
    finds = Repo.all(from f in Find, where: f.journal_entry_id in subquery(published))

    # First by position wins when a name repeats on a page.
    (Enum.sort_by(places, & &1.position) ++ Enum.sort_by(finds, & &1.position))
    |> Enum.reverse()
    |> Map.new(&{key(&1), &1})
  end

  defp rebuilt(%Bookmark{kind: "place"} = b), do: struct(Place, from_snapshot(b, @place_fields))
  defp rebuilt(%Bookmark{kind: "find"} = b), do: struct(Find, from_snapshot(b, @find_fields))

  defp from_snapshot(b, fields) do
    fields
    |> Enum.map(fn f -> {f, cast_snapshot(f, b.snapshot[to_string(f)])} end)
    |> Keyword.merge(
      id: -b.id,
      name: b.name,
      poet_id: b.poet_id,
      journal_entry_id: b.journal_entry_id
    )
  end

  defp cast_snapshot(f, v) when f in [:entry_date, :starts_on, :ends_on] and is_binary(v),
    do: Date.from_iso8601!(v)

  defp cast_snapshot(_f, v), do: v

  # A poet who turned private after the reader saved: the saved name and
  # words stay theirs, the exact position does not.
  defp unmapped(%Place{} = p), do: %{p | lat: nil, lng: nil, address: nil, media_id: nil}
  defp unmapped(%Find{} = f), do: %{f | media_id: nil}

  defp snapshot(%Place{} = p), do: take(p, @place_fields)
  defp snapshot(%Find{} = f), do: take(f, @find_fields)

  defp take(item, fields) do
    Map.new(fields, fn f ->
      v = Map.get(item, f)
      {to_string(f), if(match?(%Date{}, v), do: Date.to_iso8601(v), else: v)}
    end)
  end

  defp fetch("place", id), do: get(Place, id)
  defp fetch("find", id), do: get(Find, id)

  defp get(schema, id) do
    case Integer.parse(to_string(id)) do
      {n, ""} -> Repo.get(schema, n)
      _ -> nil
    end
  end

  defp visible?(user_id, item) do
    with %Poet{} = poet <- Repo.get(Poet, item.poet_id),
         %Entry{status: "published"} <-
           item.journal_entry_id && Repo.get(Entry, item.journal_entry_id) do
      visible_poet?(user_id, poet)
    else
      _ -> false
    end
  end

  defp visible_poet?(user_id, %Poet{} = poet), do: poet.user_id == user_id or poet.is_public
end
