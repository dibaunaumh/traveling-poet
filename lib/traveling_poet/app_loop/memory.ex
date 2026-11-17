defmodule TravelingPoet.AppLoop.Memory do
  @moduledoc """
  What an app-side poet remembers (dec-024, option D).

  A sprite poet remembers three ways: the app's context (`get_poet_context`:
  who the reader is, what they asked for, where the journey has been), the
  recent chat (`get_conversation_memory`), and its one long OpenClaw
  conversation, which holds the pages it wrote and what was said around
  them until it is compacted or set aside before a retry. An app-side run
  starts fresh, so the first two stay as they are and the third is replaced
  by this block, read from the database at the start of every run and put
  after the workspace files in the system prompt:

    * **Recent pages.** The text of the last `@pages` published pages, newest
      first, so a callback to an earlier day rests on what was published.
    * **The chat.** The reader's conversation with the poet, longer than
      `get_conversation_memory` gives (the app's own triggers left out).
    * **The notebook.** What the poet chose to keep with its `remember`
      tool, until it calls `forget`. Notes live in `app_loop_notes`; only an
      app-side run reads or writes them, so a shadow run keeps its notebook
      for real without touching anything a reader sees.

  Everything is cut off at the day being written (`entry_date`) and at
  `:before` (the moment the run starts; a shadow run passes the moment the
  sprite's run started), so a run never sees its own day.
  """

  import Ecto.Query

  alias TravelingPoet.AppLoop.Note
  alias TravelingPoet.Chat.ChatMessage
  alias TravelingPoet.Journal
  alias TravelingPoet.Journal.Entry
  alias TravelingPoet.Repo

  @pages 7
  @page_chars 1_800
  @chat_messages 60
  @message_chars 600
  @chat_chars 16_000
  @max_notes 60

  @doc "The memory block, as text for the system prompt."
  def block(poet, user, entry_date, opts \\ []) do
    before = Keyword.get(opts, :before) || DateTime.utc_now()

    [
      header(),
      pages(poet, entry_date),
      chat(user, before),
      notebook(poet, entry_date)
    ]
    |> Enum.join("\n\n")
  end

  defp header do
    """
    # Your memory

    Each run starts fresh: nothing carries over from earlier days except what \
    is below and what get_poet_context returns. When you learn something worth \
    keeping beyond today (about your companion, your journey, a promise you \
    made), save it with `remember`, one fact per note. When a note stops being \
    true, `forget` it.\
    """
  end

  ## Recent pages

  defp pages(poet, date) do
    entries =
      Repo.all(
        from e in Entry,
          where: e.poet_id == ^poet.id and e.status == "published" and e.entry_date < ^date,
          order_by: [desc: e.entry_date],
          limit: @pages,
          preload: [:sections]
      )

    start = Journal.first_published_date(poet.id)

    body =
      case entries do
        [] -> "(none yet)"
        list -> Enum.map_join(list, "\n\n", &page(&1, start))
      end

    "## Your recent pages (newest first)\n\n" <> body
  end

  defp page(entry, start) do
    heading =
      ["Day #{Journal.journey_day(entry.entry_date, start)}", Date.to_iso8601(entry.entry_date)]
      |> Kernel.++(
        Enum.reject([entry.place_name, entry.title && "\"#{entry.title}\""], &blank?/1)
      )
      |> Enum.join(" · ")

    text =
      entry.sections
      |> Enum.sort_by(& &1.position)
      |> Enum.reject(&blank?(&1.body))
      |> Enum.map_join("\n\n", fn s ->
        if blank?(s.title), do: plain(s.body), else: "#{s.title}: #{plain(s.body)}"
      end)

    ["### " <> heading, entry.teaser, clip(text, @page_chars)]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n")
  end

  ## Chat

  defp chat(user, before) do
    messages =
      Repo.all(
        from m in ChatMessage,
          where: m.user_id == ^user.id and m.inserted_at < ^to_naive(before),
          where: not (m.role == "user" and m.channel == "system"),
          order_by: [desc: m.inserted_at],
          limit: @chat_messages
      )

    # newest kept first when the whole is too long, then shown in order
    lines =
      messages
      |> Enum.map(fn m ->
        who = if m.role == "user", do: "Companion", else: "You"

        "#{who} (#{m.inserted_at |> NaiveDateTime.to_date() |> Date.to_iso8601()}): " <>
          clip(plain(m.content), @message_chars)
      end)
      |> Enum.reduce_while({[], 0}, fn line, {kept, size} ->
        size = size + String.length(line) + 1
        if size > @chat_chars, do: {:halt, {kept, size}}, else: {:cont, {[line | kept], size}}
      end)
      |> elem(0)

    body = if lines == [], do: "(no chat yet)", else: Enum.join(lines, "\n")
    "## Your chat with your companion (oldest first)\n\n" <> body
  end

  defp to_naive(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp to_naive(%NaiveDateTime{} = dt), do: dt

  ## Notebook

  defp notebook(poet, date) do
    body =
      case notes(poet.id, date) do
        [] ->
          "(empty)"

        notes ->
          Enum.map_join(notes, "\n", fn n ->
            "- [#{n.id}] #{Date.to_iso8601(n.entry_date)}: #{n.body}"
          end)
      end

    "## Your notebook (note id, the day you wrote it)\n\n" <> body
  end

  @doc "A poet's notes in force for a run on `date`, oldest first."
  def notes(poet_id, date) do
    Repo.all(
      from n in Note,
        where: n.poet_id == ^poet_id and n.entry_date < ^date,
        where: is_nil(n.forgotten_on) or n.forgotten_on >= ^date,
        order_by: [asc: n.entry_date, asc: n.id]
    )
  end

  @doc """
  The `remember` tool: `{status, reply}`. A full notebook refuses, so the
  poet chooses what to forget instead of the app dropping the oldest.
  """
  def remember(poet_id, date, note) when is_binary(note) do
    in_force = poet_id |> notes(Date.add(date, 1)) |> length()

    if in_force >= @max_notes do
      {409,
       %{
         "error" =>
           "Your notebook is full (#{@max_notes} notes). Forget one that no longer matters, then try again."
       }}
    else
      case %Note{}
           |> Note.changeset(%{poet_id: poet_id, entry_date: date, body: note})
           |> Repo.insert() do
        {:ok, n} ->
          {200, %{"ok" => true, "note_id" => n.id}}

        {:error, cs} ->
          {422,
           %{"error" => "not kept: #{inspect(Ecto.Changeset.traverse_errors(cs, &elem(&1, 0)))}"}}
      end
    end
  end

  def remember(_poet_id, _date, _note), do: {422, %{"error" => "note is required"}}

  @doc "The `forget` tool: marks one of this poet's notes forgotten from `date` on."
  def forget(poet_id, date, id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Note{poet_id: ^poet_id, forgotten_on: nil} = note <- Repo.get(Note, id) do
      note |> Note.changeset(%{forgotten_on: date}) |> Repo.update!()
      {200, %{"ok" => true}}
    else
      _ -> {404, %{"error" => "There is no note #{id} in your notebook."}}
    end
  end

  ## Text

  # Markdown to plain prose: images go, links keep their words.
  defp plain(nil), do: ""

  defp plain(text) do
    text
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, "")
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  defp clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp blank?(nil), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
