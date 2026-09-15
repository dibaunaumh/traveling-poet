defmodule TravelingPoetWeb.Api.TopicController do
  @moduledoc """
  Lets the poet propose a topic of interest it heard in chat ("I'm really
  into kit airplanes"). The same asymmetry as preferences: the poet may only
  ADD, and what it adds waits as "proposed" until the companion keeps it in
  Settings. The poet cannot activate, pause or remove a topic, and cannot
  claim the companion typed it.
  """

  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.{Poets, Topics}
  alias TravelingPoet.Topics.Topic

  def propose(conn, %{"label" => label} = params) when is_binary(label) do
    user = conn.assigns.agent_user

    with {:ok, poet} <- fetch_poet(user),
         {:ok, attrs} <- validate(params, label) do
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

    cond do
      label == "" ->
        {:error, "label cannot be blank"}

      String.length(label) > 80 ->
        {:error, "label must be 80 characters or fewer"}

      not is_nil(kind) and kind not in Topic.kinds() ->
        {:error, "kind must be one of: #{Enum.join(Topic.kinds(), ", ")}"}

      true ->
        {:ok, %{label: label, kind: kind, evidence: evidence(params)}}
    end
  end

  # The companion's own words, so Settings can show why the poet proposed it.
  defp evidence(%{"quote" => quote}) when is_binary(quote) do
    %{"quote" => String.slice(String.trim(quote), 0, 300)}
  end

  defp evidence(_params), do: %{}

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
