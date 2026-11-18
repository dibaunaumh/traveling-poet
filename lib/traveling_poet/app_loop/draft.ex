defmodule TravelingPoet.AppLoop.Draft do
  @moduledoc """
  Where a shadow run's writes go instead of the app.

  A shadow run (`AppLoop.Shadow`) writes the same day a sprite poet already
  published, for the same reader, so not one of its writes may reach the
  journal, the guide, the route or the reader. `apply/3` keeps each write in
  the draft and answers the way the endpoint would, close enough that the
  model carries on as it would on a real day:

    * `journal_put_sections` drops worded-less sections and refuses dead
      `metadata.source_url` links (`LinkCheck`), as the endpoint does.
    * `journal_publish` answers with the endpoint's own missing notes
      (`JournalApiController.missing_note/2`) for places, the drawing and a
      quiz, worked out from the draft, so a model that skipped a step is told
      the same thing a sprite poet is.
    * `generate_illustration` draws nothing (a drawing costs money and
      counts against the reader's daily image cap); it answers with a
      made-up media id. The grading leaves drawings out anyway.
    * Every other write (moving, holding, a topic, a question to the reader)
      is recorded and answered `ok`.

  `day` is `travel.day` from the context the run was given ("move", "stay",
  "excursion", "quiz"), which decides what a published page must have.
  """

  alias TravelingPoetWeb.Api.JournalApiController

  @first_media_id 900_000_000

  defstruct entry_date: nil,
            day: nil,
            entry: nil,
            sections: [],
            places: [],
            finds: nil,
            quiz: nil,
            stay_areas: [],
            media: [],
            published_at: nil,
            actions: []

  def new(entry_date, day), do: %__MODULE__{entry_date: to_string(entry_date), day: day}

  @doc "Whether the draft's page went out."
  def published?(%__MODULE__{published_at: at}), do: at != nil

  @doc """
  One write: `{status, reply, draft}`, with an HTTP-like status so the loop
  counts refusals the way it counts the app's.
  """
  def apply(draft, "journal_upsert_entry", args) do
    with :ok <- same_day(draft, args["entry_date"]) do
      entry = Map.merge(draft.entry || %{}, Map.drop(args, ["entry_date"]))

      {200,
       %{
         "ok" => true,
         "entry_id" => 0,
         "entry_date" => draft.entry_date,
         "status" => if(published?(draft), do: "published", else: "draft"),
         "excursion_linked" => draft.day == "excursion"
       }, %{draft | entry: entry}}
    else
      {:error, reply} -> {422, reply, draft}
    end
  end

  def apply(draft, "journal_put_sections", %{"sections" => sections} = args)
      when is_list(sections) do
    with :ok <- same_day(draft, args["entry_date"]),
         :ok <- entry_exists(draft),
         :ok <- live_links(sections) do
      {kept, empty} = Enum.split_with(sections, &worded_or_drawing?/1)

      reply =
        %{"ok" => true, "section_count" => length(kept)}
        |> then(fn r ->
          if empty == [],
            do: r,
            else:
              Map.put(
                r,
                "note",
                "These sections had no body and were left off the page: " <>
                  Enum.map_join(empty, "; ", &(&1["kind"] || "no kind")) <>
                  ". Send each section as one object with its kind, title and body together."
              )
        end)

      {200, reply, %{draft | sections: kept}}
    else
      {:error, reply} -> {422, reply, draft}
    end
  end

  def apply(draft, "journal_put_sections", _args),
    do: {422, %{"error" => "sections (list) is required"}, draft}

  def apply(draft, "journal_put_places", %{"places" => places} = args) when is_list(places) do
    with :ok <- same_day(draft, args["entry_date"]), :ok <- entry_exists(draft) do
      {200, %{"ok" => true, "saved" => length(places)}, %{draft | places: places}}
    else
      {:error, reply} -> {422, reply, draft}
    end
  end

  def apply(draft, "journal_put_finds", %{"finds" => finds} = args) when is_list(finds) do
    with :ok <- same_day(draft, args["entry_date"]), :ok <- entry_exists(draft) do
      {200, %{"ok" => true, "saved" => length(finds)}, %{draft | finds: args}}
    else
      {:error, reply} -> {422, reply, draft}
    end
  end

  def apply(draft, "journal_put_stay_areas", %{"areas" => areas}) when is_list(areas),
    do: {200, %{"ok" => true, "saved" => length(areas)}, %{draft | stay_areas: areas}}

  def apply(draft, "journal_put_quiz", %{"questions" => qs} = args) when is_list(qs) do
    with :ok <- same_day(draft, args["entry_date"]), :ok <- entry_exists(draft) do
      {200, %{"ok" => true, "questions" => length(qs)}, %{draft | quiz: args}}
    else
      {:error, reply} -> {422, reply, draft}
    end
  end

  def apply(draft, "generate_illustration", %{"prompt" => prompt} = args)
      when is_binary(prompt) and prompt != "" do
    id = @first_media_id + length(draft.media)
    kind = args["kind"] || "illustration"
    media = %{"id" => id, "kind" => kind, "prompt" => prompt, "sources" => args["sources"]}
    reply = %{"ok" => true, "media_id" => id, "url" => "/media/#{id}"}

    reply =
      if kind == "spot",
        do:
          Map.merge(reply, %{
            "markdown" => "![#{args["alt_text"] || "drawing"}](/media/#{id})",
            "placement" =>
              "Paste the markdown on its own line immediately BEFORE the paragraph it illustrates, " <>
                "in whichever section that paragraph lives. The drawing sits beside the paragraph that follows it."
          }),
        else: reply

    {200, reply, %{draft | media: draft.media ++ [media]}}
  end

  def apply(draft, "generate_illustration", _args),
    do: {422, %{"error" => "prompt is required"}, draft}

  def apply(draft, "journal_publish", args) do
    with :ok <- same_day(draft, args["entry_date"]), :ok <- entry_exists(draft) do
      draft = %{draft | published_at: draft.published_at || DateTime.utc_now()}
      reply = Map.merge(%{"ok" => true, "published_at" => draft.published_at}, notes(draft))
      {200, reply, draft}
    else
      {:error, reply} -> {404, reply, draft}
    end
  end

  # Moving, holding, a detour, a preference, a topic, a question for the
  # reader, the About-you note, picks near home: recorded, never sent.
  def apply(draft, tool, args) do
    {200, %{"ok" => true},
     %{draft | actions: draft.actions ++ [%{"tool" => tool, "args" => args}]}}
  end

  @doc "The draft's entry as `journal_get_entry` shows it."
  def entry_view(%__MODULE__{entry: nil}), do: nil

  def entry_view(draft) do
    Map.merge(draft.entry, %{
      "entry_date" => draft.entry_date,
      "status" => if(published?(draft), do: "published", else: "draft"),
      "sections" => draft.sections,
      "places" => draft.places
    })
  end

  @doc "What the page is missing on publish, as the endpoint says it."
  def missing(draft) do
    drawings =
      Enum.count(draft.sections, &(&1["kind"] == "illustration" and &1["media_id"] != nil)) +
        Enum.count(draft.media, &(&1["kind"] == "illustration"))

    title = (draft.entry || %{})["title"]
    titled? = is_binary(title) and String.trim(title) not in ["", "null"]

    if(titled?, do: [], else: ["title"]) ++
      case draft.day do
        "quiz" ->
          if draft.quiz, do: [], else: ["quiz"]

        day ->
          Enum.reject(
            [
              if(day != "excursion" and draft.places == [], do: "places"),
              if(drawings == 0, do: "drawing")
            ],
            &is_nil/1
          )
      end
  end

  defp notes(draft) do
    case missing(draft) do
      [] ->
        %{}

      missing ->
        %{
          "missing" => missing,
          "note" =>
            Enum.map_join(missing, " ", &JournalApiController.missing_note(&1, draft.entry_date)) <>
              " You do not need to publish again."
        }
    end
  end

  # A shadow run writes one day; a call for another date is refused, never
  # let through to that day's real page.
  defp same_day(_draft, nil), do: {:error, %{"error" => "entry_date (YYYY-MM-DD) is required"}}

  defp same_day(%{entry_date: d}, date) do
    if to_string(date) == d,
      do: :ok,
      else: {:error, %{"error" => "today's entry is #{d}; write that date"}}
  end

  defp entry_exists(%{entry: nil, entry_date: d}),
    do: {:error, %{"error" => "no entry for #{d}; call journal_upsert_entry first"}}

  defp entry_exists(_draft), do: :ok

  defp worded_or_drawing?(s) when is_map(s) do
    (is_binary(s["body"]) and String.trim(s["body"]) != "") or
      (s["kind"] == "illustration" and s["media_id"] != nil)
  end

  defp worded_or_drawing?(_), do: false

  defp live_links(sections) do
    urls =
      for %{"metadata" => %{"source_url" => url}} <- sections,
          is_binary(url) and url != "",
          do: url

    case TravelingPoet.LinkCheck.validate_all(urls) do
      :ok ->
        :ok

      {:error, bad} ->
        {:error,
         %{
           "error" =>
             "these cited links are unreachable: #{Enum.join(bad, ", ")}. " <>
               "Only cite URLs taken from pages you actually fetched and read — " <>
               "search for the organization's real site and confirm it loads before citing."
         }}
    end
  end
end
