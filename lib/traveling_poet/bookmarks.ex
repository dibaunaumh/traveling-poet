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

  The opposite verdict is a pass (card-123, `Pass`): "Not for me" on a place
  or find the reader could have saved. A passed item folds up wherever the
  reader sees it, with an Undo; it cannot be saved and passed at once. A
  pass is a taste signal: `Affinity` counts it against the item's subject,
  and the reader's own poet gets a nudge (`Preferences`, source `tap`) away
  from that subject, which hardens only if the reader keeps passing on it.
  """

  import Ecto.Query

  alias TravelingPoet.Bookmarks.{Bookmark, Pass}
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

  @doc """
  The reader's verdicts, for marking the buttons: `%{saved: keys, passed:
  keys}`. Signed out, both are empty.
  """
  def keys(nil), do: %{saved: MapSet.new(), passed: MapSet.new()}

  def keys(user_id) do
    %{saved: saved_keys(user_id), passed: passed_keys(user_id)}
  end

  defp saved_keys(user_id) do
    Bookmark
    |> where(user_id: ^user_id)
    |> select([b], {b.kind, b.journal_entry_id, b.name})
    |> Repo.all()
    |> MapSet.new()
  end

  defp passed_keys(user_id) do
    Pass
    |> where(user_id: ^user_id)
    |> select([p], {p.kind, p.journal_entry_id, p.name})
    |> Repo.all()
    |> MapSet.new()
  end

  def saved?(%{saved: keys}, item), do: MapSet.member?(keys, key(item))

  def passed?(%{passed: keys}, item), do: MapSet.member?(keys, key(item))

  @doc """
  "Not for me" on a place or find, or takes it back when already passed.
  Same visibility rule as `toggle/3`. Passing drops the item's bookmark, if
  any; the reader's own poet gets a nudge away from the item's subject.
  """
  def toggle_pass(user_id, kind, id) when kind in ["place", "find"] do
    with %{} = item <- fetch(kind, id),
         true <- visible?(user_id, item) do
      {k, entry_id, name} = key(item)
      by_key = [user_id: user_id, kind: k, journal_entry_id: entry_id, name: name]

      case Repo.get_by(Pass, by_key) do
        nil ->
          if bookmark = Repo.get_by(Bookmark, by_key), do: Repo.delete!(bookmark)

          %Pass{}
          |> Pass.changeset(%{
            user_id: user_id,
            kind: k,
            poet_id: item.poet_id,
            journal_entry_id: entry_id,
            name: name,
            category: Map.get(item, :category) || Map.get(item, :kind),
            topic: item.topic,
            second_topic: item.second_topic
          })
          |> Repo.insert()
          |> case do
            {:ok, pass} ->
              nudge_poet(user_id, pass)
              {:ok, :passed}

            error ->
              error
          end

        pass ->
          Repo.delete(pass)
          {:ok, :restored}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def toggle_pass(_user_id, _kind, _id), do: {:error, :not_found}

  @doc "The reader's passes with a subject, for the taste profile: `[%{topic, second_topic, at}]`."
  def passes(user_id) do
    Pass
    |> where([p], p.user_id == ^user_id and not is_nil(p.topic))
    |> select([p], %{topic: p.topic, second_topic: p.second_topic, at: p.inserted_at})
    |> Repo.all()
  end

  # One pass is a nudge (`Preferences`: weight 1, stale after 30 days); the
  # same subject passed again hardens it. The label is the subject's English
  # leaf, what the poet reads on the tree; a place with no subject yet uses
  # its category.
  defp nudge_poet(user_id, %Pass{} = pass) do
    with %{} = poet <- Poet |> where(user_id: ^user_id) |> Repo.one(),
         label when is_binary(label) <- pass_label(pass) do
      TravelingPoet.Preferences.record(poet.id, %{
        label: label,
        dimension: "place",
        polarity: "avoid",
        source: "tap",
        evidence: %{"passed" => pass.name}
      })
    end

    :ok
  end

  defp pass_label(%Pass{topic: topic}) when is_binary(topic) do
    case TravelingPoet.Guide.PlaceTopics.labels(topic, "en") do
      names when is_list(names) -> List.last(names)
      _ -> nil
    end
  end

  defp pass_label(%Pass{category: category}) when is_binary(category),
    do: category |> String.replace("_", " ") |> String.capitalize()

  defp pass_label(_), do: nil

  @doc """
  The token for a reader's shared Saved list, made on first share (card-93).
  Anyone with the link sees the places as the owner does, read-only.
  """
  def share(%{saved_share_token: token} = user) when is_binary(token), do: {:ok, user}

  def share(user) do
    token = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    user |> Ecto.Changeset.change(saved_share_token: token) |> Repo.update()
  end

  @doc "Stops sharing: the old link stops working, and a new share gets a new one."
  def stop_sharing(user),
    do: user |> Ecto.Changeset.change(saved_share_token: nil) |> Repo.update()

  @doc "The reader whose Saved list this token shares, or nil."
  def shared_by(token) when is_binary(token) and byte_size(token) >= 16,
    do: Repo.get_by(TravelingPoet.Accounts.User, saved_share_token: token)

  def shared_by(_), do: nil

  @doc "A reader's saved places, as their Saved view shows them."
  def places(user_id) do
    for %{item: %Place{} = place} <- list(user_id), do: place
  end

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
