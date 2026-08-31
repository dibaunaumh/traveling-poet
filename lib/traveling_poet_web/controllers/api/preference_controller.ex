defmodule TravelingPoetWeb.Api.PreferenceController do
  @moduledoc """
  Lets the poet persist a lasting preference its companion stated in chat.

  This is the endpoint that stops "dont look for delightful culture, look for
  american stupid things" from being a single-turn instruction that is
  forgotten by tomorrow.

  Two deliberate asymmetries between what the agent may do and what the user
  may do:

    * `source` is forced to `"chat"` server-side. The agent must not be able
      to claim a preference came from the user's own tap, because taps carry
      more authority — they can revive something the user removed.
    * There is no delete. The agent may only add; only the user removes. An
      agent that could un-learn a stated preference would be a bug factory,
      and `Preferences.record/2` already refuses to resurrect anything the
      user dismissed.
  """

  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.{Poets, Preferences}
  alias TravelingPoet.Preferences.Preference

  def create(conn, %{"label" => label} = params) when is_binary(label) do
    user = conn.assigns.agent_user

    with {:ok, poet} <- fetch_poet(user),
         {:ok, attrs} <- validate(params, label) do
      case Preferences.record(poet.id, attrs) do
        {:ok, preference} ->
          Logger.info("Preference recorded for poet #{poet.id}: #{preference.label}")

          json(conn, %{
            ok: true,
            label: preference.label,
            polarity: preference.polarity,
            dimension: preference.dimension,
            # Tells the agent whether this was new or a repeat, so it can
            # respond naturally rather than confirming the same thing twice.
            times_heard: preference.weight
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

  def create(conn, _params) do
    conn |> put_status(422) |> json(%{error: "label is required"})
  end

  defp fetch_poet(user) do
    case Poets.get_poet_by_user(user.id) do
      nil -> {:error, :no_poet}
      poet -> {:ok, poet}
    end
  end

  defp validate(params, label) do
    label = String.trim(label)
    dimension = params["dimension"] || "topic"
    polarity = params["polarity"] || "seek"

    cond do
      label == "" ->
        {:error, "label cannot be blank"}

      String.length(label) > 120 ->
        {:error, "label must be 120 characters or fewer"}

      dimension not in Preference.dimensions() ->
        {:error, "dimension must be one of: #{Enum.join(Preference.dimensions(), ", ")}"}

      polarity not in Preference.polarities() ->
        {:error, "polarity must be seek or avoid"}

      true ->
        {:ok,
         %{
           label: label,
           dimension: dimension,
           polarity: polarity,
           # Never trust the agent's claim about provenance.
           source: "chat",
           evidence: evidence(params)
         }}
    end
  end

  # The companion's own words, so the settings panel can show why the poet
  # believes this rather than asserting it.
  defp evidence(%{"quote" => quote}) when is_binary(quote) do
    %{"quote" => String.slice(String.trim(quote), 0, 300)}
  end

  defp evidence(_params), do: %{}

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
  end
end
