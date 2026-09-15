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

  alias TravelingPoet.Repo
  alias TravelingPoet.Topics.Topic

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
      every_days: t.every_days
    }
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
end
