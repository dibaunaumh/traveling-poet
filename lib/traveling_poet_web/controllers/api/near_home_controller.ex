defmodule TravelingPoetWeb.Api.NearHomeController do
  @moduledoc """
  The poet's picks near its companion's home (card-71, `NearHome`): stored
  as today's batch once each passes its checks, the rest answered with the
  reason so the poet can fix them and send the whole list again.
  """

  use TravelingPoetWeb, :controller

  require Logger

  alias TravelingPoet.{NearHome, Poets}

  def put(conn, %{"picks" => picks}) when is_list(picks) do
    user = conn.assigns.agent_user

    with poet when not is_nil(poet) <- Poets.get_poet_by_user(user.id),
         {:ok, %{kept: kept, dropped: dropped}} <- NearHome.ingest(user, poet, picks) do
      Logger.info("NearHome: poet #{poet.id} sent #{length(picks)}, kept #{length(kept)}")
      status = if kept == [], do: 422, else: 200

      conn
      |> put_status(status)
      |> json(%{
        ok: kept != [],
        kept: length(kept),
        dropped: dropped,
        note:
          if(dropped == [],
            do: "saved for your companion; now tell them in one short line",
            else:
              "the dropped ones are not saved: fix them and send the WHOLE list again " <>
                "(the call replaces today's list), or leave them out"
          )
      })
    else
      nil ->
        conn |> put_status(404) |> json(%{error: "no poet configured"})

      {:error, :no_home} ->
        conn
        |> put_status(409)
        |> json(%{error: "your companion has not set a home", note: "do not look near home"})
    end
  end

  def put(conn, _params) do
    conn |> put_status(422) |> json(%{error: "picks (a list) is required"})
  end
end
