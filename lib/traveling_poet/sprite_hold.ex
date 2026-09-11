defmodule TravelingPoet.SpriteHold do
  @moduledoc """
  Keeps a sprite running while the app is driving it, using the Sprites
  Tasks API (https://docs.sprites.dev/keeping-sprites-running/).

  A task is a named hold on the sprite's current run: while at least one task
  is live the sprite does not pause, and a task that nobody refreshes expires
  on its own. The API is only reachable from inside the sprite over the
  management socket `/.sprite/api.sock`, so every call here is one short
  `curl` sent through `SpritesClient.exec/3`. That exec also wakes a paused
  sprite, so wake and hold are a single round-trip.

  `with_hold/4` is the primitive a turn should use: it creates a uniquely
  named task before running the function, refreshes it on an interval while
  the function runs, and deletes it when the function returns or raises.
  Expiry is the backstop if the app dies mid-turn.
  """

  require Logger

  @socket "/.sprite/api.sock"
  @default_expire "10m"
  # Three missed refreshes fit inside the default expiry.
  @default_refresh_ms 3 * 60 * 1000

  @doc "Creates or refreshes `task_name` on `sprite_name` with the given expiry (`\"5m\"`, `\"1h\"`, max 1h)."
  def put(nil, _task_name, _expire), do: :ok

  def put(sprite_name, task_name, expire) do
    body = Jason.encode!(%{name: task_name, expire: expire})

    exec(
      sprite_name,
      "curl -sS --unix-socket #{@socket} -H 'Content-Type: application/json' " <>
        "-X PUT http://sprite/v1/tasks -d '#{body}'",
      "put #{task_name}"
    )
  end

  @doc "Deletes `task_name` on `sprite_name`. A missing task is not an error."
  def delete(nil, _task_name), do: :ok

  def delete(sprite_name, task_name) do
    exec(
      sprite_name,
      "curl -sS --unix-socket #{@socket} -X DELETE http://sprite/v1/tasks/#{task_name}",
      "delete #{task_name}"
    )
  end

  @doc "Lists the live tasks on `sprite_name` as decoded JSON. Debugging and smoke tests only."
  def list(sprite_name) do
    case client().exec(sprite_name, "curl -sS --unix-socket #{@socket} http://sprite/v1/tasks") do
      {:ok, body} when is_binary(body) -> body |> extract_text() |> Jason.decode()
      {:ok, body} -> {:ok, body}
      error -> error
    end
  end

  # Sprite exec responses wrap stdout in stream-frame and terminal control
  # bytes. Same filter as Provisioner.extract_text/1.
  defp extract_text(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.filter(fn b -> b >= 32 or b == 10 end)
    |> List.to_string()
  end

  @doc "A unique task name for one holder: `tpoet-<purpose>-<hex>`."
  def task_name(purpose) do
    suffix = :crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)
    "tpoet-#{purpose}-#{suffix}"
  end

  @doc """
  Runs `fun` while holding `sprite_name` awake.

  Options:

    * `:expire` - task expiry per refresh (default "10m")
    * `:refresh_ms` - refresh interval (default 3 min)

  A nil sprite name runs `fun` with no hold at all.
  """
  def with_hold(sprite_name, purpose, fun, opts \\ [])

  def with_hold(nil, _purpose, fun, _opts), do: fun.()

  def with_hold(sprite_name, purpose, fun, opts) do
    task_name = task_name(purpose)
    expire = Keyword.get(opts, :expire, @default_expire)
    refresh_ms = Keyword.get(opts, :refresh_ms, @default_refresh_ms)

    # The first put is synchronous so the hold exists before the work starts.
    put(sprite_name, task_name, expire)

    refresher =
      spawn_link(fn -> refresh_loop(sprite_name, task_name, expire, refresh_ms) end)

    try do
      fun.()
    after
      Process.unlink(refresher)
      Process.exit(refresher, :kill)
      Task.start(fn -> delete(sprite_name, task_name) end)
    end
  end

  defp refresh_loop(sprite_name, task_name, expire, refresh_ms) do
    Process.sleep(refresh_ms)
    put(sprite_name, task_name, expire)
    refresh_loop(sprite_name, task_name, expire, refresh_ms)
  end

  # Never raises: a failed refresh is logged and the next one retries, and the
  # linked refresher must not take the turn down with it.
  defp exec(sprite_name, command, what) do
    case client().exec(sprite_name, command) do
      {:ok, _} ->
        :ok

      {:error, reason} = error ->
        Logger.warning("SpriteHold: #{what} on #{sprite_name} failed: #{inspect(reason)}")
        error
    end
  rescue
    e ->
      Logger.warning("SpriteHold: #{what} on #{sprite_name} raised: #{Exception.message(e)}")
      {:error, e}
  end

  defp client do
    Application.get_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClient)
  end
end
