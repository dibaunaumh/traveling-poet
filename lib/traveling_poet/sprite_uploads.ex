defmodule TravelingPoet.SpriteUploads do
  @moduledoc """
  Push-side companion to `TravelingPoet.Artifacts`: copies a local file into the
  user's sprite sandbox at `~/.openclaw/workspace/uploads/<safe_name>` so the
  agent can read it from chat.

  Bytes are moved by base64-encoding the local file and shelling the result
  through `SpritesClient.exec/2` (the same primitive `Provisioner.write_file/3`
  uses). The destination filename is sanitized to a small allowlist of
  characters and prefixed with a millisecond timestamp to avoid collisions.
  """

  require Logger

  @max_bytes 25 * 1024 * 1024
  @uploads_dir "~/.openclaw/workspace/uploads"
  @workspace_relative "workspace/uploads"

  def max_bytes, do: @max_bytes
  def workspace_relative_dir, do: @workspace_relative

  @doc """
  Read `local_path` and write it into the sprite at
  `~/.openclaw/workspace/uploads/<safe>`.

  Returns `{:ok, %{sprite_path: ..., filename: ..., size: ...}}` on success.
  `sprite_path` is workspace-relative (e.g. `"workspace/uploads/<safe>"`) so it
  matches the form `Artifacts` uses on the read side and is stable to put
  inside chat messages.
  """
  @spec push_to_workspace(String.t(), String.t(), String.t()) ::
          {:ok, %{sprite_path: String.t(), filename: String.t(), size: non_neg_integer()}}
          | {:error, term()}
  def push_to_workspace(sprite_name, local_path, original_filename)
      when is_binary(sprite_name) and is_binary(local_path) and is_binary(original_filename) do
    with {:ok, %File.Stat{size: size}} when size <= @max_bytes <- File.stat(local_path),
         {:ok, bytes} <- File.read(local_path),
         safe_name = build_safe_name(original_filename),
         encoded = Base.encode64(bytes),
         cmd =
           "mkdir -p #{@uploads_dir} && echo '#{encoded}' | base64 -d > #{@uploads_dir}/#{safe_name}",
         {:ok, _} <- sprites_client().exec(sprite_name, cmd) do
      {:ok,
       %{
         sprite_path: "#{@workspace_relative}/#{safe_name}",
         filename: safe_name,
         size: size
       }}
    else
      {:ok, %File.Stat{size: size}} ->
        {:error, {:too_large, size}}

      {:error, reason} ->
        Logger.error("SpriteUploads.push_to_workspace failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Sanitize an arbitrary client-supplied filename into one that is safe to
  splice into a shell command and store on the sprite filesystem. Public so
  tests can exercise it directly.
  """
  def build_safe_name(original) when is_binary(original) do
    base =
      original
      |> Path.basename()
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "_")
      |> String.replace(~r/\.{2,}/, ".")
      |> String.trim_leading(".")
      |> String.slice(0, 200)

    base = if base == "", do: "upload", else: base
    "#{System.system_time(:millisecond)}-#{base}"
  end

  defp sprites_client do
    Application.get_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClient)
  end
end
