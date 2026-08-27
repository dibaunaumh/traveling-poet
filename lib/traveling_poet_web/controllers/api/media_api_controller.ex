defmodule TravelingPoetWeb.Api.MediaApiController do
  use TravelingPoetWeb, :controller

  alias TravelingPoet.{Journal, Poets, Usage}
  alias TravelingPoet.Storage.S3

  # base64 of ~6MB binary
  @max_base64_bytes 8_000_000
  @allowed_content_types ~w(image/png image/jpeg image/webp)

  def create(conn, %{"image_base64" => b64, "content_type" => content_type} = params)
      when is_binary(b64) do
    user = conn.assigns.agent_user

    cond do
      byte_size(b64) > @max_base64_bytes ->
        conn |> put_status(413) |> json(%{error: "image too large (max ~6MB)"})

      content_type not in @allowed_content_types ->
        conn
        |> put_status(422)
        |> json(%{error: "content_type must be one of #{Enum.join(@allowed_content_types, ", ")}"})

      not Usage.within_budget?(user, "image_gen") ->
        conn |> put_status(429) |> json(%{error: "daily image quota reached"})

      true ->
        do_create(conn, user, b64, content_type, params)
    end
  end

  def create(conn, _params) do
    conn |> put_status(422) |> json(%{error: "image_base64 and content_type are required"})
  end

  @doc """
  Server-side illustration generation: the app calls the image API (the key
  never lives on the sprite), enforces the image quota, uploads to Tigris,
  and records the media row — one tool call for the agent.
  """
  def generate(conn, %{"prompt" => prompt} = params) when is_binary(prompt) do
    user = conn.assigns.agent_user

    cond do
      String.trim(prompt) == "" ->
        conn |> put_status(422) |> json(%{error: "prompt must not be empty"})

      not TravelingPoet.Illustrations.configured?() ->
        conn |> put_status(503) |> json(%{error: "image generation is not configured"})

      not Usage.within_budget?(user, "image_gen") ->
        conn |> put_status(429) |> json(%{error: "daily image quota reached"})

      true ->
        case TravelingPoet.Illustrations.generate(prompt) do
          {:ok, bytes, content_type} ->
            do_create(
              conn,
              user,
              Base.encode64(bytes),
              content_type,
              Map.put(params, "prompt", prompt)
            )

          {:error, reason} ->
            conn |> put_status(502) |> json(%{error: "generation failed: #{inspect(reason)}"})
        end
    end
  end

  def generate(conn, _params) do
    conn |> put_status(422) |> json(%{error: "prompt is required"})
  end

  defp do_create(conn, user, b64, content_type, params) do
    with %Poets.Poet{} = poet <- Poets.get_poet_by_user(user.id),
         {:ok, bytes} <- Base.decode64(b64),
         {:ok, entry} <- resolve_entry(poet, params["entry_date"]),
         content_hash = :crypto.hash(:md5, bytes) |> Base.encode16(),
         :ok <- reject_duplicate(poet, content_hash, params["kind"]) do
      ext = extension(content_type)
      key = "poets/#{poet.id}/media/#{Ecto.UUID.generate()}#{ext}"

      case S3.upload_content(key, bytes, content_type) do
        {:ok, _} ->
          attrs = %{
            poet_id: poet.id,
            journal_entry_id: entry && entry.id,
            s3_key: key,
            content_type: content_type,
            byte_size: byte_size(bytes),
            kind: params["kind"] || "illustration",
            alt_text: params["alt_text"],
            prompt: params["prompt"],
            content_hash: content_hash,
            sources: %{"items" => normalize_sources(params["sources"])}
          }

          case Journal.create_media(attrs) do
            {:ok, media} ->
              Usage.record(user.id, "image_gen", %{metadata: %{"media_id" => media.id}})

              if media.kind == "poet_avatar" do
                Poets.update_poet(poet, %{avatar_url: "/media/#{media.id}"})
              end

              json(conn, %{ok: true, media_id: media.id, url: "/media/#{media.id}"})

            {:error, changeset} ->
              errors =
                Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)

              conn |> put_status(422) |> json(%{error: errors})
          end

        {:error, reason} ->
          conn |> put_status(502) |> json(%{error: "storage upload failed: #{inspect(reason)}"})
      end
    else
      nil ->
        conn |> put_status(404) |> json(%{error: "no poet configured"})

      :error ->
        conn |> put_status(422) |> json(%{error: "image_base64 is not valid base64"})

      {:error, :bad_date} ->
        conn |> put_status(422) |> json(%{error: "invalid entry_date"})

      {:error, {:duplicate, existing}} ->
        conn
        |> put_status(422)
        |> json(%{
          error:
            "this image is byte-identical to your existing drawing (media #{existing.id}" <>
              ", uploaded #{NaiveDateTime.to_date(existing.inserted_at)}). " <>
              "Do not reuse old drawings — generate a fresh one with generate_illustration, " <>
              "or publish without an illustration and be upfront about why."
        })
    end
  end

  # A poet re-uploading an old drawing as a "new" illustration (observed when
  # generation failed and the agent quietly substituted a stand-in) misleads
  # the reader. Avatars are exempt — re-using the portrait is legitimate.
  defp reject_duplicate(_poet, _hash, "poet_avatar"), do: :ok

  defp reject_duplicate(poet, hash, _kind) do
    case Journal.find_media_by_hash(poet.id, hash) do
      nil -> :ok
      existing -> {:error, {:duplicate, existing}}
    end
  end

  defp resolve_entry(_poet, nil), do: {:ok, nil}

  defp resolve_entry(poet, date_str) do
    case Date.from_iso8601(to_string(date_str)) do
      {:ok, date} -> {:ok, TravelingPoet.Journal.get_entry(poet.id, date)}
      {:error, _} -> {:error, :bad_date}
    end
  end

  defp normalize_sources(sources) when is_list(sources) do
    Enum.map(sources, fn
      %{"url" => _} = s -> Map.take(s, ["url", "label"])
      _ -> %{}
    end)
  end

  defp normalize_sources(_), do: []

  defp extension("image/png"), do: ".png"
  defp extension("image/jpeg"), do: ".jpg"
  defp extension("image/webp"), do: ".webp"
end
