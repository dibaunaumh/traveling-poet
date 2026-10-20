defmodule TravelingPoetWeb.Api.ReaderNoteController do
  @moduledoc """
  The poet's half of "About you" (card-125): it drafts the note while there
  is none, and once the reader has made it theirs it may only suggest one
  line to add or strike (`ReaderNote`). Each refusal says what to do instead,
  because the poet reads the reply.
  """

  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Poets, ReaderNote}

  def draft(conn, %{"text" => text}) when is_binary(text) do
    with_poet(conn, fn poet ->
      case ReaderNote.draft(poet.id, text) do
        {:ok, note} ->
          json(conn, %{ok: true, written_by: note.written_by})

        {:error, :reader_wrote_it} ->
          conn
          |> put_status(409)
          |> json(%{
            error:
              "your companion has made this note their own; you may only suggest a line " <>
                "with suggest_reader_note_line"
          })

        {:error, %Ecto.Changeset{} = changeset} ->
          conn |> put_status(422) |> json(%{error: errors(changeset)})
      end
    end)
  end

  def draft(conn, _params),
    do: conn |> put_status(422) |> json(%{error: "text is required"})

  def suggest(conn, params) do
    with_poet(conn, fn poet ->
      case ReaderNote.suggest(poet.id, Map.take(params, ["kind", "text", "reason"])) do
        {:ok, _suggestion} ->
          json(conn, %{ok: true, note: "waiting for your companion in Settings"})

        {:error, reason} when is_atom(reason) ->
          conn |> put_status(422) |> json(%{error: refusal(reason)})

        {:error, %Ecto.Changeset{} = changeset} ->
          conn |> put_status(422) |> json(%{error: errors(changeset)})
      end
    end)
  end

  defp refusal(:no_note), do: "there is no note yet; write it with write_reader_note"

  defp refusal(:not_in_note),
    do: "a strike must quote a sentence that is in the note, word for word"

  defp refusal(:already_suggested), do: "you already suggested this line; never offer it twice"
  defp refusal(:too_many), do: "three suggestions already wait for your companion; add none today"

  defp with_poet(conn, fun) do
    case Poets.get_poet_by_user(conn.assigns.agent_user.id) do
      nil -> conn |> put_status(404) |> json(%{error: "no poet configured"})
      poet -> fun.(poet)
    end
  end

  defp errors(changeset),
    do: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
end
