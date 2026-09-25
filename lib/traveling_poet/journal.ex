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
    Repo.preload(entry, sections: from(s in Section, order_by: s.position), excursion: :topic)
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
      |> tap(&link_media(entry, &1))
    end)
  end

  # A drawing made before its page existed was never linked to it; the
  # section that shows it links it now, so everything that looks for a
  # page's drawings by entry (Discover, the book) finds it. Only
  # this poet's unlinked media: nothing already on another page moves.
  defp link_media(entry, sections) do
    ids = sections |> Enum.map(& &1.media_id) |> Enum.reject(&is_nil/1)

    if ids != [] do
      Repo.update_all(
        from(m in Media,
          where: m.id in ^ids and m.poet_id == ^entry.poet_id and is_nil(m.journal_entry_id)
        ),
        set: [journal_entry_id: entry.id]
      )
    end
  end

  # Publishing an already-published entry is a REVISION: the poet re-put its
  # sections after feedback (markers, or a request in chat). `published_at`
  # stays, so FleetHealth still knows which day it was written for and the
  # Telegram/web-push notifiers are not fired a second time; only the pages
  # showing the entry are told to reload.
  def publish_entry(%Entry{status: "published"} = entry) do
    Phoenix.PubSub.broadcast(
      TravelingPoet.PubSub,
      "poet:#{entry.poet_id}",
      {:journal_revised, entry.id}
    )

    {:ok, entry}
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
      # An excursion entry going out settles its excursion for good.
      TravelingPoet.Topics.mark_published(published.id)

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

  @doc """
  A poet's entries, newest first by default.

  Options: `status:` filters; `limit:` caps the list (default 60, `:all` for
  every entry, which the book needs: a journal past its sixtieth day is not
  a journal a reader can page through 60 at a time); `order: :asc` reads the
  journey forwards.
  """
  def list_entries(poet_id, opts \\ []) do
    status = Keyword.get(opts, :status)
    limit = Keyword.get(opts, :limit, 60)
    order = Keyword.get(opts, :order, :desc)

    Entry
    |> where(poet_id: ^poet_id)
    |> maybe_filter_status(status)
    |> order_by([{^order, :entry_date}])
    |> maybe_limit(limit)
    |> Repo.all()
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, status), do: where(query, status: ^status)

  defp maybe_limit(query, :all), do: query
  defp maybe_limit(query, n) when is_integer(n), do: limit(query, ^n)

  @doc "`preload_entry/1` for a list, in the same shape, with one query per association."
  def preload_entries(entries) when is_list(entries) do
    Repo.preload(entries, sections: from(s in Section, order_by: s.position), excursion: :topic)
  end

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

  # Re-opening the same entry within this window doesn't count again — the
  # LiveView re-renders on plenty of unrelated events.
  @view_debounce_seconds 300

  @doc """
  Stamps that the poet's own reader opened this entry.

  Until this existed the app could not tell a happy silent reader from someone
  who had stopped coming back — opposite problems with opposite fixes. Called
  only for the owner, only from a live (connected) view.
  """
  def mark_owner_viewed(%Entry{} = entry, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)

    if recently_viewed?(entry, now) do
      {:ok, entry}
    else
      entry
      |> Entry.changeset(%{
        owner_viewed_at: now,
        owner_view_count: (entry.owner_view_count || 0) + 1
      })
      |> Repo.update()
    end
  end

  defp recently_viewed?(%{owner_viewed_at: nil}, _now), do: false

  defp recently_viewed?(%{owner_viewed_at: at}, now),
    do: DateTime.diff(now, at, :second) < @view_debounce_seconds

  def latest_published_entry(poet_id) do
    Entry
    |> where(poet_id: ^poet_id, status: "published")
    |> order_by(desc: :entry_date)
    |> limit(1)
    |> Repo.one()
  end

  ## Journey day

  @doc "The date this poet's journey began: its first published entry, or nil before one exists."
  def first_published_date(poet_id) do
    Entry
    |> where(poet_id: ^poet_id, status: "published")
    |> select([e], min(e.entry_date))
    |> Repo.one()
  end

  @doc """
  Which day of the journey a date falls on, counted in calendar days from the
  first published entry (Day 1), so a day the poet rested or ran out of
  credits leaves an honest gap instead of renumbering every earlier entry.
  Before anything is published the next entry will be Day 1.

  The app computes this rather than the poet: a model cannot count days
  reliably, and a number baked into a stored title would go stale on the
  first revision. `journey_day/2` is the pure form for views that already
  hold the start date.
  """
  def journey_day(%Entry{poet_id: poet_id, entry_date: date}),
    do: journey_day(date, first_published_date(poet_id))

  def journey_day(%Entry{entry_date: date}, start), do: journey_day(date, start)
  def journey_day(%Date{}, nil), do: 1
  def journey_day(%Date{} = date, %Date{} = start), do: max(Date.diff(date, start) + 1, 1)

  @doc """
  The entry's drawing for notes and link previews: the first illustration
  section's media, else the first drawing linked to the entry that no section
  claimed (the same fallback the pages render).
  """
  def entry_illustration(%Entry{} = entry) do
    entry =
      if Ecto.assoc_loaded?(entry.sections), do: entry, else: preload_entry(entry)

    from_section =
      entry.sections
      |> Enum.filter(&(&1.kind == "illustration" and &1.media_id))
      |> Enum.find_value(&get_media(&1.media_id))

    from_section || List.first(unattached_illustrations(entry, entry.sections))
  end

  ## Media

  def get_media(id), do: Repo.get(Media, id)

  @doc "The media rows for these ids, by id. Nils and unknown ids are simply absent."
  def media_by_ids(ids) do
    case ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] -> %{}
      ids -> Media |> where([m], m.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})
    end
  end

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

  Only an `illustration` section can show a drawing, so only one claims it.
  A drawing pinned to a prose section (a first entry put its Lisbon drawing
  on the description) would otherwise be claimed and never drawn.
  """
  def unattached_illustrations(%Entry{} = entry, sections) do
    Map.get(unattached_illustrations_by_entry([%{entry | sections: sections}]), entry.id, [])
  end

  @doc """
  `unattached_illustrations/2` for many entries at once (the book loads a
  whole journey): `%{entry_id => [media]}`, two queries however many entries.
  Entries must carry their sections.
  """
  def unattached_illustrations_by_entry([]), do: %{}

  def unattached_illustrations_by_entry(entries) do
    entry_ids = Enum.map(entries, & &1.id)

    referenced_by_entry =
      Map.new(entries, fn e ->
        {e.id,
         e.sections
         |> Enum.filter(&(&1.kind == "illustration"))
         |> Enum.map(& &1.media_id)
         |> Enum.reject(&is_nil/1)}
      end)

    # Guide place drawings are excluded. They belong to a place, not to the
    # prose, and this query renders anything it returns as a stray taped photo
    # on the journal page. The media controller already leaves
    # journal_entry_id nil for them; this is the second lock, and it also
    # covers rows the backfill may have linked.
    claimed_by_places =
      from(p in TravelingPoet.Guide.Place,
        where: p.journal_entry_id in ^entry_ids and not is_nil(p.media_id),
        select: p.media_id
      )

    Media
    |> where([m], m.journal_entry_id in ^entry_ids and m.kind == "illustration")
    |> where([m], m.id not in subquery(claimed_by_places))
    |> order_by(asc: :id)
    |> Repo.all()
    |> Enum.reject(fn m -> m.id in Map.get(referenced_by_entry, m.journal_entry_id, []) end)
    |> Enum.group_by(& &1.journal_entry_id)
  end

  @doc """
  The entry's spot drawings: small ink vignettes the poet embeds inside the
  prose as `![alt](/media/:id)`. They never render as taped photos (the
  unattached query is illustration-only); the renderer lets a body embed
  exactly these ids and nothing else.
  """
  def spot_media(%Entry{id: entry_id}) do
    Map.get(spot_media_by_entry([entry_id]), entry_id, [])
  end

  @doc "`spot_media/1` for many entries: `%{entry_id => [media]}`, one query."
  def spot_media_by_entry([]), do: %{}

  def spot_media_by_entry(entry_ids) do
    Media
    |> where([m], m.journal_entry_id in ^entry_ids and m.kind == "spot")
    |> order_by(asc: :id)
    |> Repo.all()
    |> Enum.group_by(& &1.journal_entry_id)
  end

  @doc "The markdown the poet pastes into the prose to place a spot drawing."
  def spot_markdown(%Media{id: id, alt_text: alt}) do
    "![#{String.replace(alt || "drawing", ~r/[\[\]]/, "")}](/media/#{id})"
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
