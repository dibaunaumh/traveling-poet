defmodule TravelingPoet.Guide.PlaceClassifier do
  @moduledoc """
  Sorts places into the topic tree (`Guide.PlaceTopics`): up to two topics
  and a place type per place, one model call for a batch of places.

  A server-side text LLM call, like `Guide.Extractor`, and for the same
  reason: this is the app keeping its own records consistent, not the poet
  writing. Asking each poet to pick from 157 topics in every
  `journal_put_places` would cost every sprite the whole tree in context and
  trust the one step poets have fumbled before (events left out of places).

  It only ever labels what the poet wrote: name, category, blurb, address and
  the city the entry is about. Nothing it returns is shown as the poet's
  words, and everything it returns is checked: a path not in the tree is
  dropped, a type not in the list becomes "other", a place it did not answer
  for (or answered only with topics outside the tree) is left for the next
  run.
  """

  require Logger

  alias TravelingPoet.Guide.PlaceTopics

  @api_url "https://openrouter.ai/api/v1/chat/completions"

  def configured?(opts \\ []), do: api_key(opts) not in [nil, ""]

  @doc "The model: EXTRACTION_MODEL, the cheap one the places backfill already uses."
  def model,
    do: Application.get_env(:traveling_poet, :extraction_model, "google/gemini-2.5-flash")

  @doc """
  Classifies a batch. Each place is a map with `:id`, `:name`, `:category`
  and optionally `:blurb`, `:address`, `:city`.

  Returns `{:ok, %{id => %{topic, second_topic, place_type}}}`, where `topic`
  is nil for a row that is not a place anyone could visit (a town mentioned
  in passing, an organisation, a train line), or `{:error, reason}`.
  """
  def classify(places, opts \\ [])

  def classify([], _opts), do: {:ok, %{}}

  def classify(places, opts) do
    case api_key(opts) do
      key when key in [nil, ""] -> {:error, :not_configured}
      key -> request(key, places)
    end
  end

  defp api_key(opts),
    do: Keyword.get(opts, :api_key, Application.get_env(:traveling_poet, :openrouter_api_key))

  defp request(key, places) do
    body = %{
      model: model(),
      messages: [
        %{role: "system", content: system_prompt()},
        %{role: "user", content: user_prompt(places)}
      ],
      response_format: %{type: "json_object"},
      temperature: 0
    }

    options =
      [
        json: body,
        headers: [{"authorization", "Bearer #{key}"}],
        receive_timeout: 90_000
      ] ++ Application.get_env(:traveling_poet, :place_classifier_req_options, [])

    case Req.post(@api_url, options) do
      {:ok, %{status: 200, body: resp}} ->
        {:ok, resp |> content() |> parse_response(Enum.map(places, & &1.id))}

      {:ok, %{status: status, body: resp}} ->
        Logger.warning(
          "PlaceClassifier: OpenRouter returned #{status}: #{inspect(resp, limit: 300)}"
        )

        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("PlaceClassifier: request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp content(%{"choices" => [%{"message" => %{"content" => c}} | _]}) when is_binary(c), do: c
  defp content(_), do: ""

  @doc """
  Turns the model's reply into verdicts for the ids that were asked about.

  Public because this is where the risk lives: a malformed or partial reply
  must never break a run or write a topic outside the tree. Accepts
  `{"places": [...]}` or a bare list, in markdown fences or not; ids not
  asked about are ignored; an id it did not answer for is simply absent.
  """
  def parse_response(raw, asked_ids) when is_binary(raw) do
    asked = MapSet.new(asked_ids, &to_string/1)

    raw
    |> String.trim()
    |> String.replace(~r/\A```(?:json)?\s*/i, "")
    |> String.replace(~r/```\s*\z/, "")
    |> Jason.decode()
    |> case do
      {:ok, %{"places" => list}} when is_list(list) -> list
      {:ok, list} when is_list(list) -> list
      _ -> []
    end
    |> Enum.filter(&(is_map(&1) and MapSet.member?(asked, to_string(&1["id"]))))
    |> Enum.flat_map(fn verdict ->
      given = verdict |> Map.get("topics", []) |> List.wrap()
      topics = given |> Enum.filter(&(is_binary(&1) and PlaceTopics.valid?(&1))) |> Enum.uniq()

      # Topics named but none in the tree: a bad answer, not a verdict that
      # the row is no place. Left for the next run, never "untaggable".
      if given != [] and topics == [] do
        []
      else
        [
          {id_of(verdict["id"], asked_ids),
           %{
             topic: Enum.at(topics, 0),
             second_topic: Enum.at(topics, 1),
             place_type:
               if(topics == [], do: nil, else: PlaceTopics.normalize_type(verdict["type"]))
           }}
        ]
      end
    end)
    |> Map.new()
  end

  def parse_response(_, _), do: %{}

  # The id as it was asked (an integer), not as the model echoed it.
  defp id_of(id, asked_ids), do: Enum.find(asked_ids, &(to_string(&1) == to_string(id)))

  defp user_prompt(places) do
    lines =
      Enum.map(places, fn p ->
        [
          "id=#{p.id}",
          "name=#{p.name}",
          "category=#{p.category}",
          p[:city] && "city=#{p.city}",
          p[:address] && "address=#{p.address}",
          p[:blurb] && "about=#{String.slice(p.blurb, 0, 300)}"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" | ")
      end)

    "Classify these places:\n\n" <> Enum.join(lines, "\n")
  end

  @doc false
  def system_prompt do
    topics =
      Enum.map_join(PlaceTopics.paths(), "\n", fn path ->
        "#{path}  (#{Enum.join(PlaceTopics.names(path), " > ")})"
      end)

    """
    You file the places a travel writer found into a fixed topic tree, so readers
    can browse the world's places by subject (every textile museum, workshop and
    exhibition side by side).

    For each place, return:
      id      the id you were given
      topics  one or two topic paths from the list below, the best fit first.
              Add a second only when the place is truly both (a jazz supper club:
              a restaurant AND a jazz venue). Use exactly the paths listed.
              Every real place gets at least one topic: when nothing fits
              exactly, choose the CLOSEST one (a German restaurant with no
              German topic still goes under food, in the nearest cuisine).
              Return [] ONLY when the row is not somewhere a visitor could go:
              a whole town or region mentioned in passing, a person, an
              organisation or website, a train line.
      type    what kind of place it is, one of:
              #{Enum.join(PlaceTopics.types(), ", ")}

    File by SUBJECT, not by what the building is: an exhibition of textiles goes
    under textiles; a temple is filed by its faith; a restaurant by its cuisine.
    Events (festivals, exhibitions, concerts) go by their subject; their type is
    exhibition or festival_or_event.

    Reply with JSON only: {"places": [{"id": 1, "topics": ["..."], "type": "..."}]}

    Topic paths:
    #{topics}
    """
  end
end
