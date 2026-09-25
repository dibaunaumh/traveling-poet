defmodule TravelingPoetWeb.Api.AskController do
  @moduledoc """
  The poet asks its companion a question in chat (`Asks`). Only on a day the
  app chose: `ask_reader` in `/api/agent/context` says when, and a question
  on any other day is refused with a note, never kept.
  """

  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.{Asks, Poets}

  def create(conn, %{"question" => question}) when is_binary(question) do
    user = conn.assigns.agent_user

    case Poets.get_poet_by_user(user.id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "no poet configured"})

      poet ->
        case Asks.create(poet, question) do
          {:ok, ask} ->
            Logger.info("Poet #{poet.id} asked its reader (#{ask.reason}): ask #{ask.id}")

            json(conn, %{
              ok: true,
              ask: %{id: ask.id, about: ask.about},
              note:
                "sent to your companion, with a notification; when they answer " <>
                  "with an interest, call propose_topic with ask_id #{ask.id}"
            })

          {:error, :not_due} ->
            conn
            |> put_status(409)
            |> json(%{
              error: "not today",
              note: "the app decides when to ask (ask_reader in get_poet_context); do not ask"
            })

          {:error, changeset} ->
            conn
            |> put_status(422)
            |> json(%{
              error: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
            })
        end
    end
  end

  def create(conn, _params) do
    conn |> put_status(422) |> json(%{error: "question is required"})
  end
end
