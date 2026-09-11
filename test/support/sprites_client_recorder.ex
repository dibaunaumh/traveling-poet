defmodule TravelingPoet.SpritesClientRecorder do
  @moduledoc """
  Stand-in for `TravelingPoet.SpritesClient` in tests. Every `exec/3` is
  forwarded as `{:sprites_exec, sprite_name, command}` to the pid registered
  under `:sprites_client_listener` in the app env, and replies `{:ok, ""}`.

  Install it per test with:

      Application.put_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClientRecorder)
      Application.put_env(:traveling_poet, :sprites_client_listener, self())

  and clean both up in `on_exit`.
  """

  def exec(sprite_name, command, _opts \\ []) do
    case Application.get_env(:traveling_poet, :sprites_client_listener) do
      pid when is_pid(pid) -> send(pid, {:sprites_exec, sprite_name, command})
      _ -> :ok
    end

    {:ok, ""}
  end
end
