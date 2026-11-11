defmodule TravelingPoetWeb.Plugs.AiCTap do
  @moduledoc "Emits an AiC activity for every agent-originated /api/agent call, after the response is sent."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      with %{id: user_id} <- conn.assigns[:agent_user],
           controller when not is_nil(controller) <- conn.private[:phoenix_controller] do
        name = controller |> Module.split() |> List.last() |> Macro.underscore()

        TravelingPoet.AiC.api_call(
          user_id,
          name,
          conn.private[:phoenix_action],
          conn.status || 200
        )

        page_changed(conn, user_id, controller, conn.private[:phoenix_action])
      end

      conn
    end)
  end

  # What the poet puts on a page after publishing it (the places, the finds,
  # the drawing) changes what the page holds, so the page is reported again.
  @page_actions %{
    TravelingPoetWeb.Api.JournalApiController =>
      ~w(put_sections put_places put_finds put_stay_areas)a,
    TravelingPoetWeb.Api.MediaApiController => ~w(create generate)a
  }

  defp page_changed(conn, user_id, controller, action) do
    params = if is_struct(conn.params), do: %{}, else: conn.params
    date = conn.path_params["date"] || params["entry_date"]

    if conn.status in 200..299 and is_binary(date) and
         action in Map.get(@page_actions, controller, []) do
      TravelingPoet.AiC.page_changed(user_id, date)
    end
  end
end
