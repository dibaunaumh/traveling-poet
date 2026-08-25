defmodule TravelingPoet.Artifacts do
  @moduledoc """
  Read-through passthrough for files produced by a user's OpenClaw agent in
  their sprite sandbox (`~/.openclaw/workspace/`).

  Because `SpritesClient` only exposes `exec/3`, bytes are moved out of the
  sprite by `base64 -w 0` on the remote side and decoded here. File metadata is
  probed with `stat` first so we can enforce a size cap before pulling bytes.

  Results are cached on local disk under a per-sprite namespace, keyed by the
  remote file's mtime — a rewrite on the sprite side invalidates the cache for
  free on the next `stat`.
  """

  require Logger

  @workspace_root "~/.openclaw/workspace"
  @max_bytes 25 * 1024 * 1024
  @max_path_bytes 1024

  def workspace_root, do: @workspace_root
  def max_bytes, do: @max_bytes

  @doc """
  Validate a caller-supplied relative path. Returns `{:ok, rel}` where `rel`
  is known to be free of shell metacharacters and any `..` escape, or
  `{:error, :invalid_path}`.
  """
  def validate_path(raw) when is_binary(raw) do
    with :ok <- check_bytes(raw),
         {:ok, rel} <- safe_relative(raw),
         :ok <- check_chars(rel) do
      {:ok, rel}
    end
  end

  def validate_path(_), do: {:error, :invalid_path}

  defp check_bytes(s) do
    cond do
      byte_size(s) == 0 -> {:error, :invalid_path}
      byte_size(s) > @max_path_bytes -> {:error, :invalid_path}
      String.contains?(s, <<0>>) -> {:error, :invalid_path}
      true -> :ok
    end
  end

  defp safe_relative(raw) do
    case Path.safe_relative(raw) do
      {:ok, p} -> {:ok, p}
      :error -> {:error, :invalid_path}
    end
  end

  # Whitelist: alnum, dash, underscore, dot, slash. Reject literal ".." as a
  # defence-in-depth layer on top of `Path.safe_relative/1`.
  defp check_chars(p) do
    if Regex.match?(~r/\A[A-Za-z0-9_.\/\-]+\z/, p) and not String.contains?(p, "..") do
      :ok
    else
      {:error, :invalid_path}
    end
  end

  @doc """
  Resolve a validated relative path to the absolute sprite-side path. Does not
  expand `~` — that is left to the remote shell to interpret.
  """
  def absolute_path(rel) when is_binary(rel) do
    @workspace_root <> "/" <> rel
  end

  @doc """
  Ensure the file is present in the local cache; fetch it from the sprite on
  miss. Returns `{:ok, local_path}` or an error.
  """
  def ensure_cached(sprite_name, rel_path) do
    abs_path = absolute_path(rel_path)

    with {:ok, %{mtime: mtime}} <- stat(sprite_name, abs_path) do
      local = cache_path(sprite_name, rel_path, mtime)

      if File.exists?(local) do
        {:ok, local}
      else
        fetch_to(local, sprite_name, abs_path)
      end
    end
  end

  @doc """
  Probe size and mtime for a file inside the sprite. Returns
  `{:ok, %{size: non_neg_integer(), mtime: integer()}}` or an error. Empty
  stdout (e.g., file missing — stderr is redirected) → `:not_found`.
  """
  def stat(sprite_name, abs_path) do
    cmd = "stat -c '%s %Y' -- #{abs_path} 2>/dev/null"

    case sprites_client().exec(sprite_name, cmd) do
      {:ok, body} ->
        text = body |> extract_text() |> String.trim()
        Logger.debug("Artifacts.stat raw=#{inspect(body, limit: 200)} text=#{inspect(text)}")

        text
        |> parse_stat()
        |> classify_size()

      {:error, reason} ->
        Logger.warning("Artifacts.stat sprites error: #{inspect(reason)}")
        {:error, {:sprites, reason}}
    end
  end

  defp parse_stat(""), do: :not_found

  defp parse_stat(line) do
    case String.split(line, " ", parts: 2) do
      [size_str, mtime_str] ->
        with {size, ""} <- Integer.parse(size_str),
             {mtime, ""} <- Integer.parse(String.trim(mtime_str)) do
          {:ok, size, mtime}
        else
          _ -> :not_found
        end

      _ ->
        :not_found
    end
  end

  defp classify_size(:not_found), do: {:error, :not_found}
  defp classify_size({:ok, size, _mtime}) when size > @max_bytes, do: {:error, :too_large}
  defp classify_size({:ok, size, mtime}), do: {:ok, %{size: size, mtime: mtime}}

  defp fetch_to(local, sprite_name, abs_path) do
    cmd = "base64 -w 0 -- #{abs_path}"

    with {:ok, body} <- sprites_client().exec(sprite_name, cmd),
         sanitized = body |> extract_text() |> keep_base64_chars(),
         {:ok, bin} <- decode64(sanitized) do
      File.mkdir_p!(Path.dirname(local))
      tmp = local <> ".tmp"
      File.write!(tmp, bin)
      File.rename!(tmp, local)
      {:ok, local}
    else
      :error ->
        {:error, :not_found}

      {:error, reason} ->
        Logger.warning("Artifacts.fetch sprites error: #{inspect(reason)}")
        {:error, {:sprites, reason}}
    end
  end

  defp decode64(""), do: :error
  defp decode64(s), do: Base.decode64(s)

  # Sprite `exec` responses carry terminal control bytes around the real stdout.
  # Match Provisioner.extract_text/1: keep printable ASCII and newlines.
  defp extract_text(data) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.filter(fn b -> b >= 32 or b == 10 end)
    |> List.to_string()
  end

  defp extract_text(other), do: to_string(other)

  # Restrict to the base64 alphabet before decoding, in case noise remains.
  defp keep_base64_chars(s) do
    String.replace(s, ~r/[^A-Za-z0-9+\/=]/, "")
  end

  defp cache_path(sprite_name, rel_path, mtime) do
    root = Application.get_env(:traveling_poet, :artifact_cache_dir, default_cache_dir())
    Path.join([root, sprite_name, "#{rel_path}.#{mtime}"])
  end

  defp default_cache_dir, do: Path.join(System.tmp_dir!(), "tpoet_artifacts")

  defp sprites_client do
    Application.get_env(:traveling_poet, :sprites_client, TravelingPoet.SpritesClient)
  end
end
