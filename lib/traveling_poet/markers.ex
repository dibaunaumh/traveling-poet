defmodule TravelingPoet.Markers do
  @moduledoc """
  Feedback markers: the notes a reader drops on passages of an entry, and how
  they reach the poet.

  A marker is created from the journal page and sits `pending` (no `sent_at`)
  until `TravelingPoet.Markers.Delivery` bundles everything on an entry into
  one digest for the agent, after the reader has gone quiet for a while.
  Markers stay after delivery so the page can show what was already sent and
  so the agent can see recurring kinds across days via `recent_payload/2`.
  """

  import Ecto.Query

  alias TravelingPoet.Repo
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Journal.{Entry, Marker}

  @doc """
  Records a marker for this user on this entry. Idempotent: an identical
  pending marker is returned instead of duplicated, so a double tap or a
  re-fired selection event is harmless.

  `attrs` may carry string or atom keys and JSON-typed values (integers as
  strings), as the browser hook sends them.
  """
  def add_marker(%User{id: user_id}, %Entry{id: entry_id}, attrs) do
    attrs = normalize(attrs)

    case find_identical(user_id, entry_id, attrs) do
      nil ->
        %Marker{}
        |> Marker.changeset(Map.merge(attrs, %{user_id: user_id, journal_entry_id: entry_id}))
        |> Repo.insert()
        |> tap(fn
          {:ok, _} -> TravelingPoet.AiC.marker_added(user_id, entry_id, attrs)
          _ -> :ok
        end)

      existing ->
        {:ok, existing}
    end
  end

  @doc """
  One of the buttons under the main drawing. A drawing holds one pending
  rating at a time: pressing the pending one again takes it back, pressing
  another replaces it. Returns `{:ok, marker}`, or `{:ok, nil}` when the
  press took the rating back.

  A rating already sent stays; pressing it again asks once more (the redraw
  it asked for may have failed).
  """
  def rate_drawing(%User{id: user_id} = user, %Entry{} = entry, media_id, kind) do
    with true <- kind in Marker.drawing_kinds(),
         media_id when is_integer(media_id) <- to_int(media_id) do
      pending =
        Marker
        |> where(user_id: ^user_id, journal_entry_id: ^entry.id, media_id: ^media_id)
        |> where([m], m.target == "illustration" and is_nil(m.sent_at))
        |> where([m], m.kind in ^Marker.drawing_kinds())
        |> Repo.all()

      Enum.each(pending, &Repo.delete/1)

      if Enum.any?(pending, &(&1.kind == kind)) do
        {:ok, nil}
      else
        add_marker(user, entry, %{
          kind: kind,
          target: "illustration",
          section_kind: "illustration",
          section_position: drawing_position(entry, media_id),
          media_id: media_id
        })
      end
    else
      _ -> {:error, :invalid}
    end
  end

  defp drawing_position(%Entry{sections: sections}, media_id) when is_list(sections) do
    Enum.find_value(sections, &(&1.media_id == media_id && &1.position))
  end

  defp drawing_position(_entry, _media_id), do: nil

  @doc "Deletes one of the user's own markers. `{:error, :not_found}` for anyone else's."
  def remove_marker(user_id, id) do
    case to_int(id) do
      nil ->
        {:error, :not_found}

      id ->
        case Repo.get_by(Marker, id: id, user_id: user_id) do
          nil -> {:error, :not_found}
          marker -> Repo.delete(marker)
        end
    end
  end

  @doc """
  Sets the free-text note on one of the user's own markers (the "Other
  feedback" kind asks for one right after the mark is placed).
  """
  def update_note(user_id, id, note) do
    with id when not is_nil(id) <- to_int(id),
         %Marker{} = marker <- Repo.get_by(Marker, id: id, user_id: user_id) do
      marker
      |> Marker.changeset(%{note: note |> presence() |> trim()})
      |> Repo.update()
    else
      _ -> {:error, :not_found}
    end
  end

  def list_markers(entry_id) do
    Marker
    |> where(journal_entry_id: ^entry_id)
    |> order_by(asc: :inserted_at, asc: :id)
    |> Repo.all()
  end

  @doc "JSON-safe view of markers, for the page's data attribute and the agent."
  def payload(markers) do
    Enum.map(markers, fn m ->
      %{
        id: m.id,
        kind: m.kind,
        label: Marker.label(m.kind),
        target: m.target,
        section_kind: m.section_kind,
        section_position: m.section_position,
        media_id: m.media_id,
        quote: m.quote,
        prefix: m.prefix,
        suffix: m.suffix,
        note: m.note,
        sent: not is_nil(m.sent_at)
      }
    end)
  end

  @doc """
  Pending markers grouped by entry: `[{entry_id, newest_inserted_at, markers}]`.
  The newest timestamp is what the quiet period is measured from.
  """
  def pending_by_entry do
    Marker
    |> where([m], is_nil(m.sent_at))
    |> order_by(asc: :inserted_at, asc: :id)
    |> Repo.all()
    |> Enum.group_by(& &1.journal_entry_id)
    |> Enum.map(fn {entry_id, markers} ->
      newest = markers |> Enum.map(& &1.inserted_at) |> Enum.max(NaiveDateTime)
      {entry_id, newest, markers}
    end)
  end

  def mark_sent(ids, now \\ DateTime.utc_now()) when is_list(ids) do
    now = DateTime.truncate(now, :second)

    Marker
    |> where([m], m.id in ^ids)
    |> Repo.update_all(set: [sent_at: now])
  end

  @doc "Markers on this poet's entries since `since`, for the agent's feedback digest."
  def recent_payload(poet_id, %DateTime{} = since) do
    from(m in Marker,
      join: e in Entry,
      on: m.journal_entry_id == e.id,
      where: e.poet_id == ^poet_id,
      where: m.inserted_at >= ^since,
      order_by: [asc: e.entry_date, asc: m.section_position, asc: m.id],
      select: %{
        entry_date: e.entry_date,
        kind: m.kind,
        target: m.target,
        section_kind: m.section_kind,
        quote: m.quote,
        sent_at: m.sent_at,
        inserted_at: m.inserted_at
      }
    )
    |> Repo.all()
  end

  @doc "How many times each kind was used on this poet's entries since `since`."
  def counts_since(poet_id, %DateTime{} = since) do
    from(m in Marker,
      join: e in Entry,
      on: m.journal_entry_id == e.id,
      where: e.poet_id == ^poet_id,
      where: m.inserted_at >= ^since,
      group_by: m.kind,
      select: {m.kind, count(m.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  # -- helpers --

  defp find_identical(user_id, entry_id, attrs) do
    Marker
    |> where(user_id: ^user_id, journal_entry_id: ^entry_id)
    |> where([m], is_nil(m.sent_at))
    |> Repo.all()
    |> Enum.find(fn m ->
      {m.kind, m.target, m.section_kind, m.section_position, m.media_id, m.quote} ==
        {attrs[:kind], attrs[:target], attrs[:section_kind], attrs[:section_position],
         attrs[:media_id], attrs[:quote]}
    end)
  end

  defp normalize(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    %{
      kind: attrs["kind"],
      target: attrs["target"],
      section_kind: presence(attrs["section_kind"]),
      section_position: to_int(attrs["section_position"]),
      media_id: to_int(attrs["media_id"]),
      quote: attrs["quote"] |> presence() |> trim(),
      prefix: attrs["prefix"] |> presence() |> clip(Marker.context_max()),
      suffix: attrs["suffix"] |> presence() |> clip(Marker.context_max()),
      note: attrs["note"] |> presence() |> trim()
    }
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(v) when is_binary(v), do: v
  defp presence(v), do: to_string(v)

  defp trim(nil), do: nil
  defp trim(s), do: String.trim(s)

  defp clip(nil, _max), do: nil
  defp clip(s, max), do: String.slice(s, 0, max)

  defp to_int(nil), do: nil
  defp to_int(i) when is_integer(i), do: i

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, ""} -> i
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
