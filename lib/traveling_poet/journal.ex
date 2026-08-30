defmodule TravelingPoet.Journal do
  @moduledoc """
  The Journal context: entries, typed sections, media (illustrations with
  source links), and reactions.
  """

  import Ecto.Query
  alias TravelingPoet.Repo
  alias TravelingPoet.Journal.{Entry, Section, Media, Reaction}

  ## Entries

  def get_entry!(id), do: Repo.get!(Entry, id)

  def get_entry(poet_id, %Date{} = date),
    do: Repo.get_by(Entry, poet_id: poet_id, entry_date: date)

  def get_entry_preloaded(poet_id, %Date{} = date) do
    case get_entry(poet_id, date) do
      nil -> nil
      entry -> preload_entry(entry)
    end
  end

  def preload_entry(entry) do
    Repo.preload(entry, sections: from(s in Section, order_by: s.position))
  end

  @doc "Upserts the entry for (poet, date) — the agent write-back path is idempotent by date."
  def upsert_entry(poet_id, %Date{} = date, attrs) do
    case get_entry(poet_id, date) do
      nil ->
        %Entry{}
        |> Entry.changeset(Map.merge(attrs, %{poet_id: poet_id, entry_date: date}))
        |> Repo.insert()

      entry ->
        entry
        |> Entry.changeset(Map.drop(attrs, [:poet_id, :entry_date, "poet_id", "entry_date"]))
        |> Repo.update()
    end
  end

  @doc "Replaces an entry's sections wholesale (agent sends the full ordered list)."
  def replace_sections(%Entry{} = entry, sections_attrs) when is_list(sections_attrs) do
    Repo.transaction(fn ->
      Repo.delete_all(from(s in Section, where: s.journal_entry_id == ^entry.id))

      sections_attrs
      |> Enum.with_index()
      |> Enum.map(fn {attrs, i} ->
        %Section{}
        |> Section.changeset(
          attrs
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.put("journal_entry_id", entry.id)
          |> Map.put_new("position", i)
        )
        |> Repo.insert!()
      end)
    end)
  end

  def publish_entry(%Entry{} = entry) do
    result =
      entry
      |> Entry.changeset(%{
        status: "published",
        published_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update()

    with {:ok, published} <- result do
      Phoenix.PubSub.broadcast(
        TravelingPoet.PubSub,
        "poet:#{entry.poet_id}",
        {:journal_published, published.id}
      )

      # Global topic for cross-cutting listeners (Telegram notifier, landing map)
      Phoenix.PubSub.broadcast(
        TravelingPoet.PubSub,
        "journal:published",
        {:journal_published, entry.poet_id, published.id}
      )

      {:ok, published}
    end
  end

  def list_entries(poet_id, opts \\ []) do
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 60)

    Entry
    |> where(poet_id: ^poet_id)
    |> maybe_filter_status(status)
    |> order_by(desc: :entry_date)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, status: ^status)

  @doc """
  Whether this poet published anything at or after `since` — the daily run's
  real outcome. A run that talked but never published hasn't happened.
  """
  def published_since?(poet_id, %DateTime{} = since) do
    Entry
    |> where([e], e.poet_id == ^poet_id and e.status == "published")
    |> where([e], e.published_at >= ^since)
    |> Repo.exists?()
  end

  def latest_published_entry(poet_id) do
    Entry
    |> where(poet_id: ^poet_id, status: "published")
    |> order_by(desc: :entry_date)
    |> limit(1)
    |> Repo.one()
  end

  ## Media

  def get_media(id), do: Repo.get(Media, id)

  @doc "An existing media row for this poet with identical bytes, if any."
  def find_media_by_hash(poet_id, content_hash) when is_binary(content_hash) do
    Media
    |> where(poet_id: ^poet_id, content_hash: ^content_hash)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Illustrations uploaded for an entry that no section references — happens
  when the agent generates the drawing but fumbles the final
  journal_put_sections wiring (observed with cheaper models). The renderer
  shows these anyway so a fumble never costs the reader the drawing.
  """
  def unattached_illustrations(%Entry{} = entry, sections) do
    referenced = sections |> Enum.map(& &1.media_id) |> Enum.reject(&is_nil/1)

    Media
    |> where(journal_entry_id: ^entry.id, kind: "illustration")
    |> where([m], m.id not in ^referenced)
    |> Repo.all()
  end

  def create_media(attrs) do
    %Media{}
    |> Media.changeset(attrs)
    |> Repo.insert()
  end

  ## Reactions

  def toggle_reaction(entry_id, user_id, kind, visibility, note \\ nil) do
    case Repo.get_by(Reaction,
           journal_entry_id: entry_id,
           user_id: user_id,
           kind: kind,
           visibility: visibility
         ) do
      nil ->
        %Reaction{}
        |> Reaction.changeset(%{
          journal_entry_id: entry_id,
          user_id: user_id,
          kind: kind,
          visibility: visibility,
          note: note
        })
        |> Repo.insert()

      reaction ->
        Repo.delete(reaction)
    end
  end

  def list_reactions(entry_id, visibility) do
    Reaction
    |> where(journal_entry_id: ^entry_id, visibility: ^visibility)
    |> Repo.all()
  end

  @doc """
  Digest of the owner's private reactions since a given time — surfaced to the
  agent (via GET /api/agent/context) as its taste-learning signal.
  """
  def private_feedback_since(poet_id, %DateTime{} = since) do
    from(r in Reaction,
      join: e in Entry,
      on: r.journal_entry_id == e.id,
      where: e.poet_id == ^poet_id and r.visibility == "private",
      where: r.inserted_at >= ^since,
      select: %{entry_date: e.entry_date, kind: r.kind, note: r.note}
    )
    |> Repo.all()
  end
end
