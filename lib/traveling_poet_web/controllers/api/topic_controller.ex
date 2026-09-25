defmodule TravelingPoetWeb.Api.TopicController do
  @moduledoc """
  Lets the poet propose a topic of interest it heard in chat ("I'm really
  into kit airplanes"). The same asymmetry as preferences: the poet may only
  ADD, and what it adds waits as "proposed" until the companion keeps it in
  Settings. The poet cannot activate, pause or remove a topic, and cannot
  claim the companion typed it.

  The exception is an answer: with `ask_id` naming the poet's recent ask
  (`Asks`), the companion's answer becomes an active topic at once. An
  `ask_id` that is not this poet's recent ask is ignored, and the topic is
  only proposed.
  """

  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.{Asks, Poets, Topics}
  alias TravelingPoet.Topics.Topic

  def propose(conn, %{"label" => label} = params) when is_binary(label) do
    user = conn.assigns.agent_user

    with {:ok, poet} <- fetch_poet(user),
         {:ok, attrs} <- validate(params, label) do
      case Asks.answerable(poet.id, params["ask_id"]) do
        nil -> propose_topic(conn, poet, attrs)
        ask -> add_from_answer(conn, poet, ask, attrs)
      end
    else
      {:error, :no_poet} ->
        conn |> put_status(404) |> json(%{error: "no poet configured"})

      {:error, message} ->
        conn |> put_status(422) |> json(%{error: message})
    end
  end

  def propose(conn, _params) do
    conn |> put_status(422) |> json(%{error: "label is required"})
  end

  defp add_from_answer(conn, poet, ask, attrs) do
    # An answer to a question about a domain is a taste in it, whatever the
    # poet passed.
    attrs = if ask.about in Topic.domains(), do: Map.put(attrs, :domain, ask.about), else: attrs

    case Topics.add_from_ask(poet.id, attrs) do
      {:ok, topic, outcome} ->
        {:ok, _} = Asks.mark_answered(ask)

        if outcome in [:added, :kept],
          do: Logger.info("Topic from an answer for poet #{poet.id}: #{topic.label}")

        json(conn, %{
          ok: true,
          topic: Topics.topic_payload(topic),
          active: topic.status == "active",
          already_known: outcome != :added,
          note: answer_note(outcome)
        })

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: errors(changeset)})
    end
  end

  defp answer_note(:added),
    do: "active now: an excursion into it comes soon; they can change it in Settings"

  defp answer_note(:kept), do: "they had it waiting in Settings; it is active now"
  defp answer_note(:already_active), do: "already one of their topics"
  defp answer_note(:paused), do: "they paused this topic; leave it paused, do not press it"

  defp propose_topic(conn, poet, attrs) do
    case Topics.propose(poet.id, attrs) do
      {:ok, topic, already_known} ->
        unless already_known,
          do: Logger.info("Topic proposed for poet #{poet.id}: #{topic.label}")

        json(conn, %{
          ok: true,
          topic: Topics.topic_payload(topic),
          # Tells the poet whether this is news, so it does not announce
          # the same topic twice.
          already_known: already_known,
          note: note(topic, already_known)
        })

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: errors(changeset)})
    end
  end

  @doc """
  The companion asked in chat for an excursion ("go to the Big Ears
  festival for me"). Queues one; the next stay day takes it, and the reply
  carries `travel` so the poet can say when. A topic the companion has not
  kept yet is proposed alongside: the explicit request is its own
  confirmation for one day, no more.
  """
  def request(conn, %{"destination" => destination} = params) when is_binary(destination) do
    user = conn.assigns.agent_user

    with {:ok, poet} <- fetch_poet(user),
         {:ok, destination} <- validate_destination(destination),
         {:ok, topic} <- resolve_topic(poet, params) do
      {url, dropped} = checked_url(params["url"])

      case Topics.request_excursion(poet.id, topic, %{
             requested_destination: destination,
             requested_url: url
           }) do
        {:ok, excursion} ->
          Logger.info("Excursion requested for poet #{poet.id}: #{destination} (#{topic.label})")

          json(conn, %{
            ok: true,
            excursion: %{
              id: excursion.id,
              topic: Topics.topic_payload(topic),
              destination: destination
            },
            dropped_url: dropped,
            # When it will actually happen: a move day always goes first.
            travel: Poets.travel_plan(poet)
          })

        {:error, changeset} ->
          conn |> put_status(422) |> json(%{error: errors(changeset)})
      end
    else
      {:error, :no_poet} ->
        conn |> put_status(404) |> json(%{error: "no poet configured"})

      {:error, message} when is_binary(message) ->
        conn |> put_status(422) |> json(%{error: message})

      {:error, changeset} ->
        conn |> put_status(422) |> json(%{error: errors(changeset)})
    end
  end

  # A plugin from before the rename still sends `venue`; the fleet is
  # upgraded poet by poet after a deploy.
  def request(conn, %{"venue" => venue} = params) when is_binary(venue) do
    request(conn, params |> Map.delete("venue") |> Map.put("destination", venue))
  end

  def request(conn, _params) do
    conn |> put_status(422) |> json(%{error: "destination is required"})
  end

  defp validate_destination(destination) do
    case String.trim(destination) do
      "" -> {:error, "destination cannot be blank"}
      v when byte_size(v) > 160 -> {:error, "destination must be 160 characters or fewer"}
      v -> {:ok, v}
    end
  end

  # By id, by label (an existing topic under that key), or a new proposal.
  defp resolve_topic(poet, %{"topic_id" => id}) when is_integer(id) do
    case Topics.get(poet.id, id) do
      nil -> {:error, "no topic with that id; pass the topic's label instead"}
      topic -> {:ok, topic}
    end
  end

  defp resolve_topic(poet, %{"topic" => label}) when is_binary(label) do
    case String.trim(label) do
      "" ->
        {:error, "topic cannot be blank"}

      label ->
        case Topics.propose(poet.id, %{label: label}) do
          {:ok, topic, _known} -> {:ok, topic}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp resolve_topic(_poet, _params), do: {:error, "topic (label) or topic_id is required"}

  # A dead link is dropped, never fatal: the destination's name is what the
  # excursion runs on.
  defp checked_url(url) when is_binary(url) and url != "" do
    if TravelingPoet.LinkCheck.check(url) == :ok, do: {url, nil}, else: {nil, url}
  end

  defp checked_url(_), do: {nil, nil}

  defp note(_topic, false),
    do: "proposed; your companion keeps or drops it in Settings"

  defp note(%Topic{status: "active"}, true), do: "already one of their topics"
  defp note(%Topic{status: "paused"}, true), do: "they paused this topic; do not bring it up"
  defp note(_topic, true), do: "already proposed; waiting for them in Settings"

  defp fetch_poet(user) do
    case Poets.get_poet_by_user(user.id) do
      nil -> {:error, :no_poet}
      poet -> {:ok, poet}
    end
  end

  defp validate(params, label) do
    label = String.trim(label)
    kind = params["kind"]
    domain = blank_to_nil(params["domain"])

    cond do
      label == "" ->
        {:error, "label cannot be blank"}

      String.length(label) > 80 ->
        {:error, "label must be 80 characters or fewer"}

      not is_nil(kind) and kind not in Topic.kinds() ->
        {:error, "kind must be one of: #{Enum.join(Topic.kinds(), ", ")}"}

      not is_nil(domain) and domain not in Topic.domains() ->
        {:error, "domain must be one of: #{Enum.join(Topic.domains(), ", ")}"}

      true ->
        {:ok, %{label: label, kind: kind, domain: domain, evidence: evidence(params)}}
    end
  end

  # The companion's own words, so Settings can show why the poet proposed it.
  defp evidence(%{"quote" => quote}) when is_binary(quote) do
    %{"quote" => String.slice(String.trim(quote), 0, 300)}
  end

  defp evidence(_params), do: %{}

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      v -> v
    end
  end

  defp blank_to_nil(_), do: nil

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
