defmodule TravelingPoet.ReaderNote do
  @moduledoc """
  "About you" (card-125, dec-011): one plain note about the reader in
  Settings, in place of asking for their interests four ways.

  The rules, which keep the reader's words the reader's:

    * The poet drafts it (`draft/2`) when there is none, from what it
      already knows, and may redraft only while it is still its own draft.
    * Once the reader saves it (`save/2`) or accepts a line, it is theirs.
      From then on the poet may only `suggest/2` one line to add or strike,
      at most #{3} waiting at once; a declined line is never suggested again.
    * On every reader save the app reads the note (`understand/1`,
      `Extractor`) and ADDS what it finds: tastes and topics through
      `Topics`, avoids through `Preferences` (source `settings`, so they
      outrank inference). It never removes a topic or a preference: those
      lists keep their own Remove buttons, below the note.

  The poet reads the note on every run (`payload/1`, `about_you` in the
  context) as the reader's own words.
  """

  import Ecto.Query

  alias TravelingPoet.{Preferences, Repo, Topics}
  alias TravelingPoet.ReaderNote.{Extractor, Note, Suggestion}

  @max_pending 3

  def get(poet_id), do: Repo.get_by(Note, poet_id: poet_id)

  @doc "The suggestions waiting on the reader, oldest first."
  def pending(poet_id) do
    Suggestion
    |> where(poet_id: ^poet_id, status: "pending")
    |> order_by(asc: :id)
    |> Repo.all()
  end

  @doc "What the poet is told: the note, who wrote it, and what is waiting."
  def payload(poet_id) do
    case get(poet_id) do
      nil ->
        %{text: nil, written_by: nil, needs_draft: true, pending_suggestions: []}

      note ->
        %{
          text: note.text,
          written_by: note.written_by,
          needs_draft: false,
          pending_suggestions: Enum.map(pending(poet_id), &%{kind: &1.kind, text: &1.text})
        }
    end
  end

  @doc "The poet's draft. Refused once the reader has made the note theirs."
  def draft(poet_id, text) when is_binary(text) do
    case get(poet_id) do
      nil -> %Note{} |> Note.changeset(%{poet_id: poet_id, text: text}) |> Repo.insert()
      %Note{written_by: "poet"} = note -> note |> Note.changeset(%{text: text}) |> Repo.update()
      %Note{} -> {:error, :reader_wrote_it}
    end
  end

  def draft(_poet_id, _text), do: {:error, :no_text}

  @doc """
  The poet suggests one line. `kind` "add" (a new sentence) or "strike" (a
  sentence that is in the note now, word for word).
  """
  def suggest(poet_id, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    text = String.trim(to_string(attrs["text"] || ""))

    cond do
      is_nil(get(poet_id)) ->
        {:error, :no_note}

      attrs["kind"] == "strike" and not String.contains?(get(poet_id).text, text) ->
        {:error, :not_in_note}

      seen?(poet_id, text) ->
        {:error, :already_suggested}

      length(pending(poet_id)) >= @max_pending ->
        {:error, :too_many}

      true ->
        %Suggestion{}
        |> Suggestion.changeset(Map.merge(attrs, %{"poet_id" => poet_id, "text" => text}))
        |> Repo.insert()
    end
  end

  # Waiting, or already answered either way: never ask twice.
  defp seen?(poet_id, text) do
    Repo.exists?(
      from(s in Suggestion,
        where: s.poet_id == ^poet_id and fragment("lower(?)", s.text) == ^String.downcase(text)
      )
    )
  end

  @doc """
  The reader's own save. A blank note is cleared, and the poet drafts again.
  """
  def save(poet_id, text) when is_binary(text) do
    case {get(poet_id), String.trim(text)} do
      {nil, ""} ->
        {:ok, nil}

      {%Note{} = note, ""} ->
        with {:ok, _} <- Repo.delete(note), do: {:ok, nil}

      {nil, text} ->
        %Note{}
        |> Note.changeset(%{poet_id: poet_id, text: text, written_by: "reader"})
        |> Repo.insert()

      {note, text} ->
        note |> Note.changeset(%{text: text, written_by: "reader"}) |> Repo.update()
    end
  end

  @doc "The reader takes a suggested line: it goes into (or out of) the note."
  def accept(poet_id, suggestion_id) do
    with %Suggestion{status: "pending"} = s <- get_suggestion(poet_id, suggestion_id),
         %Note{} = note <- get(poet_id) do
      Repo.transaction(fn ->
        s |> Suggestion.changeset(%{status: "accepted"}) |> Repo.update!()

        note
        |> Note.changeset(%{text: apply_line(note.text, s), written_by: "reader"})
        |> Repo.update!()
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The reader declines a suggested line; the poet will not offer it again."
  def decline(poet_id, suggestion_id) do
    case get_suggestion(poet_id, suggestion_id) do
      %Suggestion{status: "pending"} = s ->
        s |> Suggestion.changeset(%{status: "declined"}) |> Repo.update()

      _ ->
        {:error, :not_found}
    end
  end

  defp get_suggestion(poet_id, id), do: Repo.get_by(Suggestion, id: id, poet_id: poet_id)

  @doc false
  def apply_line(text, %Suggestion{kind: "add", text: line}) do
    line = if String.ends_with?(line, [".", "!", "?"]), do: line, else: line <> "."
    String.trim_trailing(text) <> " " <> line
  end

  def apply_line(text, %Suggestion{kind: "strike", text: line}) do
    text
    |> String.replace(line, "", global: false)
    |> String.replace(~r/[ \t]{2,}/, " ")
    |> String.replace(~r/ +([.,;])/, "\\1")
    |> String.trim()
  end

  @doc """
  Reads the note and adds what it says: tastes and topics, active at once
  (the reader wrote them), and avoids as preferences. Stores the reading on
  the note for Settings to show. `{:ok, note}`, or `{:ok, :skipped}` when
  there is no note or no extraction model.
  """
  def understand(poet_id) do
    with %Note{} = note <- get(poet_id),
         {:ok, reading} <- Extractor.extract(note.text) do
      added = apply_reading(poet_id, reading)

      note
      |> Note.changeset(%{
        understood: added,
        understood_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.update()
    else
      nil -> {:ok, :skipped}
      {:error, :not_configured} -> {:ok, :skipped}
      {:error, _} = error -> error
    end
  end

  defp apply_reading(poet_id, %{tastes: tastes, topics: topics, avoids: avoids}) do
    tastes =
      for %{domain: domain, label: label} <- tastes,
          ensure_topic(poet_id, %{label: label, domain: domain}) do
        %{"domain" => domain, "label" => label}
      end

    topics =
      for %{label: label} <- topics, ensure_topic(poet_id, %{label: label}) do
        %{"label" => label}
      end

    avoids =
      for label <- avoids, avoid(poet_id, label) do
        %{"label" => label}
      end

    %{"tastes" => tastes, "topics" => topics, "avoids" => avoids}
  end

  defp avoid(poet_id, label) do
    match?(
      {:ok, _},
      Preferences.record(poet_id, %{
        label: label,
        dimension: "topic",
        polarity: "avoid",
        source: "settings",
        evidence: %{"from" => "about_you"}
      })
    )
  end

  # Already followed: kept as it is (a proposed one becomes the reader's).
  # New: active at once, as if typed into the list.
  defp ensure_topic(poet_id, attrs) do
    case Topics.get_by_label(poet_id, attrs.label) do
      nil ->
        match?({:ok, _}, Topics.create(poet_id, attrs))

      %{status: "proposed"} = topic ->
        match?({:ok, _}, Topics.keep(topic))

      _topic ->
        true
    end
  end
end
