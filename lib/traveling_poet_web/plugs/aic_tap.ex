defmodule TravelingPoetWeb.Plugs.AiCTap do
  @moduledoc "Emits an AiC activity for every agent-originated /api/agent call, after the response is sent."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    register_before_send(conn, fn conn ->
      with %{id: user_id} <- conn.assigns[:agent_user],
           controller when not is_nil(controller) <- conn.private[:phoenix_controller] do
        name = controller |> Module.split() |> List.last() |> Macro.underscore()
        TravelingPoet.AiC.api_call(user_id, name, conn.private[:phoenix_action], conn.status || 200)
      end

      conn
    end)
  end
end
