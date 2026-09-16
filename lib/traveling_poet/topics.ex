defmodule TravelingPoet.Topics do
  @moduledoc """
  The companion's topics of interest and the poet's excursions into them.

  Two writers with different authority, as with preferences: the companion
  creates, edits, pauses and removes topics in Settings; the poet may only
  PROPOSE one (`propose/2`, from what the companion said in chat), which waits
  as "proposed" until the companion keeps it. The poet never activates,
  pauses or deletes a topic.
  """

  import Ecto.Query, except: [update: 2, update: 3]

  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Preferences.EntryPrompt
  alias TravelingPoet.Repo
  alias TravelingPoet.Topics.{Excursion, Find, Topic}

  @taken ~w(written published)

  ## Reading

  @doc "Every topic of the poet, in the companion's order."
  def list(poet_id) do
    Topic
    |> where(poet_id: ^poet_id)
    |> order_by(asc: :position, asc: :id)
    |> Repo.all()
  end

  @doc "Topics that get scheduled excursions."
  def list_active(poet_id) do
    Topic
    |> where(poet_id: ^poet_id, status: "active")
    |> order_by(asc: :position, asc: :id)
    |> Repo.all()
  end

  def get(poet_id, id), do: Repo.get_by(Topic, id: id, poet_id: poet_id)

  def get_by_label(poet_id, label) when is_binary(label) do
    Repo.get_by(Topic, poet_id: poet_id, key: Topic.derive_key(label))
  end

  @doc """
  What the poet is told about its companion's topics: the active ones and the
  ones it proposed and is waiting on. Paused topics are left out, so the poet
  does not keep bringing up something the companion set aside.
  """
  def payload(poet_id) do
    Topic
    |> where(poet_id: ^poet_id)
    |> where([t], t.status in ["active", "proposed"])
    |> order_by(asc: :position, asc: :id)
    |> Repo.all()
    |> Enum.map(&topic_payload/1)
  end

  def topic_payload(%Topic{} = t) do
    %{
      id: t.id,
      label: t.label,
      kind: t.kind,
      status: t.status,
      every_days: t.every_days,
      last_excursion_on: last_on(t),
      excursions_count: taken_count(t.id),
      # How the companion answered the question under the last excursion
      # into this topic (an option id such as "more_like_this"), or nil.
      last_answer: last_answer(t.id)
    }
  end

  defp taken_count(topic_id) do
    Excursion
    |> where(topic_id: ^topic_id)
    |> where([e], e.status in @taken)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  defp last_answer(topic_id) do
    from(p in EntryPrompt,
      join: x in Excursion,
      on: x.journal_entry_id == p.journal_entry_id,
      where: x.topic_id == ^topic_id and not is_nil(p.answered_at),
      order_by: [desc: p.answered_at],
      limit: 1,
      select: p.answer_option_id
    )
    |> Repo.one()
  end

  ## The companion's writes (Settings)

  @doc "A topic the companion typed in: active at once."
  def create(poet_id, attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("poet_id", poet_id)
      |> Map.put_new("status", "active")
      |> Map.put_new("source", "settings")
      |> Map.put_new("position", next_position(poet_id))

    %Topic{}
    |> Topic.changeset(attrs)
    |> Repo.insert()
  end

  def update(%Topic{} = topic, attrs) do
    topic
    |> Topic.changeset(attrs)
    |> Repo.update()
  end

  @doc "The companion keeps a topic the poet proposed."
  def keep(%Topic{} = topic), do: update(topic, %{status: "active", source: "settings"})

  def pause(%Topic{} = topic), do: update(topic, %{status: "paused"})

  def resume(%Topic{} = topic), do: update(topic, %{status: "active"})

  def delete(%Topic{} = topic), do: Repo.delete(topic)

  ## The poet's write (chat)

  @doc """
  The poet heard a standing interest in chat. Creates the topic as "proposed"
  from chat; an existing topic under the same key is returned unchanged
  (whatever its status: a paused topic stays paused, the companion decided
  that), flagged `already_known`.

  Returns `{:ok, topic, already_known?}`.
  """
  def propose(poet_id, attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("poet_id", poet_id)
      |> Map.put("status", "proposed")
      |> Map.put("source", "chat")
      |> Map.put("position", next_position(poet_id))

    case get_by_label(poet_id, attrs["label"] || "") do
      %Topic{} = existing ->
        {:ok, existing, true}

      nil ->
        case %Topic{} |> Topic.changeset(attrs) |> Repo.insert() do
          {:ok, topic} -> {:ok, topic, false}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp next_position(poet_id) do
    Topic
    |> where(poet_id: ^poet_id)
    |> select([t], max(t.position))
    |> Repo.one()
    |> case do
      nil -> 0
      max -> max + 1
    end
  end

  ## Excursions: the decision's inputs

  @doc """
  The excursion already on today's date, whatever its status, so a retry
  after a failed run reproduces the same decision with the same row.
  """
  def excursion_for_today(poet_id, today) do
    Excursion
    |> where(poet_id: ^poet_id, scheduled_for: ^today)
    |> preload(:topic)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Was yesterday an excursion day? Two in a row is a poet who stopped travelling."
  def excursion_yesterday?(poet_id, today) do
    yesterday = Date.add(today, -1)

    Excursion
    |> where(poet_id: ^poet_id, scheduled_for: ^yesterday)
    |> where([e], e.status in @taken)
    |> Repo.exists?()
  end

  @doc "The oldest excursion the companion asked for in chat and has not had."
  def queued_chat_excursion(poet_id) do
    Excursion
    |> where(poet_id: ^poet_id, status: "queued", source: "chat")
    |> order_by(asc: :id)
    |> preload(:topic)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  The active topic whose turn it is: due when it has never had an excursion
  or its last one is at least `every_days` old, and among the due ones the
  longest waiting goes first (never had one, then oldest last excursion),
  then the companion's order. Nil when no topic is due.
  """
  def due_topic(poet_id, today) do
    poet_id
    |> list_active()
    |> Enum.map(&{&1, last_on(&1)})
    |> Enum.filter(fn {t, last} -> is_nil(last) or Date.diff(today, last) >= t.every_days end)
    |> Enum.sort_by(fn {t, last} -> {last && Date.to_iso8601(last), t.position, t.id} end)
    |> case do
      [] -> nil
      [{topic, _} | _] -> topic
    end
  end

  @doc """
  For Settings: when this topic's next excursion falls due. `:due` when it
  is (never had one, or the cadence has elapsed), else the days to wait.
  """
  def days_until_due(%Topic{} = topic, today \\ Date.utc_today()) do
    case last_on(topic) do
      nil ->
        :due

      last ->
        max(topic.every_days - Date.diff(today, last), 0)
        |> then(&if(&1 == 0, do: :due, else: &1))
    end
  end

  @doc "The date of the last excursion taken into this topic, or nil."
  def last_excursion_on(%Topic{} = topic), do: last_on(topic)

  # nil sorts first in Elixir's term order (nil < binary), which is exactly
  # "never had one goes first".
  defp last_on(%Topic{id: topic_id}) do
    Excursion
    |> where(topic_id: ^topic_id)
    |> where([e], e.status in @taken)
    |> select([e], max(e.scheduled_for))
    |> Repo.one()
  end

  @doc """
  Excursion days taken since the poet arrived where it is. They do not count
  as days at the place: a three-day stay with one excursion lasts four.
  """
  def excursion_days_since(poet_id, %Date{} = arrived_on) do
    Excursion
    |> where(poet_id: ^poet_id)
    |> where([e], e.status in @taken and e.scheduled_for >= ^arrived_on)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  def excursion_days_since(_poet_id, nil), do: 0

  def excursion_payload(nil), do: nil

  def excursion_payload(%Excursion{} = x) do
    topic = x.topic

    %{
      id: x.id,
      topic_id: x.topic_id,
      label: topic && topic.label,
      kind: topic && topic.kind,
      requested_venue: x.requested_venue,
      requested_url: x.requested_url,
      source: x.source
    }
  end

  ## Excursions: writes

  @doc """
  The companion asked in chat to go somewhere for a topic. Queues one
  excursion; the next stay day takes it. Returns `{:ok, excursion}` with the
  topic loaded.
  """
  def request_excursion(poet_id, %Topic{} = topic, attrs) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.merge(%{
        "poet_id" => poet_id,
        "topic_id" => topic.id,
        "status" => "queued",
        "source" => "chat"
      })

    with {:ok, excursion} <- %Excursion{} |> Excursion.changeset(attrs) |> Repo.insert() do
      {:ok, %{excursion | topic: topic}}
    end
  end

  @doc """
  Ties today's entry to its excursion, when the poet wrote one.

  With an `excursion_id` (the row `travel.excursion` named) the row is
  claimed; with only a `topic_id`, a queued chat request for that topic is
  claimed first, else the row is created. Either way the entry's place fields
  are cleared: the poet did not move today. `{:ok, nil}` when the params
  name no excursion.
  """
  def link_entry(%Entry{} = entry, params) do
    excursion_id = to_int(params["excursion_id"])
    topic_id = to_int(params["topic_id"])

    cond do
      excursion_id ->
        case Repo.get_by(Excursion, id: excursion_id, poet_id: entry.poet_id) do
          nil -> {:error, :unknown_excursion}
          excursion -> claim(excursion, entry)
        end

      topic_id ->
        case get(entry.poet_id, topic_id) do
          nil ->
            {:error, :unknown_topic}

          topic ->
            existing =
              get_excursion_for_entry(entry.id) ||
                queued_for_topic(entry.poet_id, topic.id) ||
                %Excursion{poet_id: entry.poet_id, topic_id: topic.id, source: "app"}

            claim(existing, entry)
        end

      true ->
        {:ok, nil}
    end
  end

  defp claim(%Excursion{} = excursion, %Entry{} = entry) do
    Repo.transaction(fn ->
      # A different entry already has this excursion: the row is the log of
      # that day, and today gets its own.
      excursion =
        if excursion.journal_entry_id && excursion.journal_entry_id != entry.id,
          do: %Excursion{poet_id: excursion.poet_id, topic_id: excursion.topic_id, source: "app"},
          else: excursion

      # Linked after the entry already went out (a re-upsert): it is taken.
      status =
        if excursion.status == "published" or entry.status == "published",
          do: "published",
          else: "written"

      {:ok, saved} =
        excursion
        |> Excursion.changeset(%{
          journal_entry_id: entry.id,
          scheduled_for: entry.entry_date,
          status: status
        })
        |> Repo.insert_or_update()

      {:ok, _} =
        entry
        |> Entry.changeset(%{place_name: nil, lat: nil, lng: nil})
        |> Repo.update()

      Repo.preload(saved, :topic)
    end)
  end

  defp queued_for_topic(poet_id, topic_id) do
    Excursion
    |> where(poet_id: ^poet_id, topic_id: ^topic_id, status: "queued")
    |> order_by(asc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "The entry went out; the excursion is taken for good."
  def mark_published(entry_id) do
    Excursion
    |> where(journal_entry_id: ^entry_id)
    |> Repo.update_all(set: [status: "published", updated_at: DateTime.utc_now()])

    :ok
  end

  @doc "Where the poet actually went, once it knows."
  def set_venue(%Excursion{} = excursion, attrs) do
    excursion
    |> Excursion.changeset(Map.take(attrs, [:venue_name, :venue_url, "venue_name", "venue_url"]))
    |> Repo.update()
  end

  def get_excursion_for_entry(nil), do: nil

  def get_excursion_for_entry(entry_id) do
    Excursion
    |> where(journal_entry_id: ^entry_id)
    |> preload(:topic)
    |> Repo.one()
  end

  @doc """
  The excursion on an entry, whether it came preloaded, was never loaded, or
  the entry is a bare map in a test or a pure builder. Nil when the entry is
  a day at a place.
  """
  def excursion_of(nil), do: nil

  def excursion_of(entry) do
    case Map.get(entry, :excursion) do
      %Ecto.Association.NotLoaded{} -> get_excursion_for_entry(Map.get(entry, :id))
      other -> other
    end
  end

  @doc ~s|"excursion: <topic>" for an excursion entry, nil otherwise; for admin rows and notes.|
  def label_for_entry(entry) do
    case excursion_of(entry) do
      %{topic: %{label: label}} when is_binary(label) -> label
      %{topic_id: topic_id} when is_integer(topic_id) -> Repo.get(Topic, topic_id).label
      _ -> nil
    end
  end

  @doc "Published excursions into this topic dated before the entry."
  def published_excursions_before(topic_id, %Date{} = date) do
    Excursion
    |> where(topic_id: ^topic_id, status: "published")
    |> where([e], e.scheduled_for < ^date)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  @doc "Chat requests still waiting, for Settings."
  def list_queued(poet_id) do
    Excursion
    |> where(poet_id: ^poet_id, status: "queued")
    |> order_by(asc: :id)
    |> preload(:topic)
    |> Repo.all()
  end

  def get_excursion(poet_id, id), do: Repo.get_by(Excursion, id: id, poet_id: poet_id)

  def delete_excursion(%Excursion{} = excursion), do: Repo.delete(excursion)

  ## The guide's view of excursions

  # Published means both: the excursion was taken and its entry is out. A
  # draft's finds never reach the guide, as a draft's places never do.
  defp published_excursions_query(poet_id) do
    from(x in Excursion,
      join: e in Entry,
      on: e.id == x.journal_entry_id,
      where: x.poet_id == ^poet_id and x.status == "published" and e.status == "published"
    )
  end

  @doc """
  The topics that have something to show in the guide, with how many
  excursions each has had, in the companion's order. A paused topic with
  past excursions is still listed: what the poet found stays findable.
  """
  def list_guide_topics(poet_id) do
    counts =
      published_excursions_query(poet_id)
      |> group_by([x], x.topic_id)
      |> select([x], {x.topic_id, count(x.id)})
      |> Repo.all()
      |> Map.new()

    Topic
    |> where([t], t.id in ^Map.keys(counts))
    |> order_by(asc: :position, asc: :id)
    |> Repo.all()
    |> Enum.map(&{&1, Map.fetch!(counts, &1.id)})
  end

  @doc "A topic's published excursions, oldest first, each with its topic loaded."
  def list_published_excursions(poet_id, topic_id) do
    published_excursions_query(poet_id)
    |> where([x], x.topic_id == ^topic_id)
    |> order_by([x], asc: x.scheduled_for, asc: x.id)
    |> preload(:topic)
    |> Repo.all()
  end

  ## Finds

  def list_finds_for_entry(nil), do: []

  def list_finds_for_entry(entry_id) do
    Find
    |> where(journal_entry_id: ^entry_id)
    |> order_by(asc: :position)
    |> Repo.all()
  end

  @doc "`list_finds_for_entry/1` for many entries: `%{entry_id => [find]}`, one query."
  def list_finds_for_entries([]), do: %{}

  def list_finds_for_entries(entry_ids) do
    Find
    |> where([f], f.journal_entry_id in ^entry_ids)
    |> order_by(asc: :position)
    |> Repo.all()
    |> Enum.group_by(& &1.journal_entry_id)
  end

  def get_find(poet_id, id) when is_integer(id), do: Repo.get_by(Find, id: id, poet_id: poet_id)
  def get_find(_poet_id, _id), do: nil

  @doc """
  Replaces an entry's finds wholesale, as `Guide.replace_places/2` does, and
  keeps a drawing across the replace when the find keeps its name.
  """
  def replace_finds(%Entry{} = entry, finds_attrs) when is_list(finds_attrs) do
    kept = finds_media_by_name(entry.id)

    Repo.transaction(fn ->
      Repo.delete_all(from(f in Find, where: f.journal_entry_id == ^entry.id))

      finds_attrs
      |> Enum.with_index()
      |> Enum.map(fn {attrs, i} ->
        attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
        name = attrs |> Map.get("name", "") |> to_string() |> String.trim()

        %Find{}
        |> Find.changeset(
          attrs
          |> Map.merge(Map.get(kept, name, %{}))
          |> Map.put("poet_id", entry.poet_id)
          |> Map.put("journal_entry_id", entry.id)
          |> Map.put("entry_date", entry.entry_date)
          |> Map.put("position", i)
        )
        |> Repo.insert()
        |> case do
          {:ok, find} -> find
          # A find without a URL is not a find; the whole list is refused
          # with the reason, and the previous list stays.
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  defp finds_media_by_name(entry_id) do
    Find
    |> where(journal_entry_id: ^entry_id)
    |> where([f], not is_nil(f.media_id))
    |> Repo.all()
    |> Map.new(&{&1.name, %{"media_id" => &1.media_id}})
  end

  def attach_find_media(%Find{} = find, media_id) do
    find |> Find.changeset(%{media_id: media_id}) |> Repo.update()
  end

  defp to_int(nil), do: nil
  defp to_int(n) when is_integer(n), do: n

  defp to_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp to_int(_), do: nil
end
