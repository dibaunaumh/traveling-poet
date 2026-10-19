defmodule TravelingPoet.Narration do
  @moduledoc """
  The entry read aloud (card-122): one mp3 per published entry, generated
  app-side through OpenRouter's speech endpoint and stored in Tigris as a
  media row of kind "narration", served by `/media/:id` like a drawing.

  Narration is rendering, so it happens HERE and never on the sprite, for
  the same reason as illustrations: no shared secret reaches a poet's
  sandbox, and the fleet key is the one bill. The 2026-10-15 eval (evt in
  Alice.In) found 35 speech models behind the key; the model and voice are
  config (`NARRATION_MODEL`, `NARRATION_VOICE`), nil model = feature off.
  A page is read in its own language (`entry.language`): a Hebrew page takes
  `NARRATION_MODEL_HE` / `NARRATION_VOICE_HE` (dec-009: Grok Voice "leo";
  the English voice reads Hebrew with an accent), each falling back to the
  default when unset.

  `generate/1` is the whole unit of work: script, hash check, speech call,
  upload, media row, old row gone, usage recorded. On demand only (dec-004,
  2026-10-16): nothing is read at publish, a page is read the first time
  someone presses the ring on it (`Narration.Worker.request/1`) and the
  recording stays for the next listener. A revision of a published page
  drops a recording whose words changed (`drop_stale/1`), so the next press
  reads it again. The opt-in switch and the publish-time worker of dec-003
  are gone with it.
  """

  require Logger
  import Ecto.Query

  alias TravelingPoet.{Accounts, Journal, Repo, Usage}
  alias TravelingPoet.Journal.{Entry, Media}
  alias TravelingPoet.Narration.{Mp3, Script}

  @speech_url "https://openrouter.ai/api/v1/audio/speech"
  @usage_kind "narration"

  def configured?, do: model() not in [nil, ""]

  def model, do: Application.get_env(:traveling_poet, :narration_model)
  def voice, do: Application.get_env(:traveling_poet, :narration_voice)

  @doc "The speech model for a page in `language`."
  def model("he"),
    do: present(Application.get_env(:traveling_poet, :narration_model_he)) || model()

  def model(_language), do: model()

  @doc "The voice for a page in `language`."
  def voice("he"),
    do: present(Application.get_env(:traveling_poet, :narration_voice_he)) || voice()

  def voice(_language), do: voice()

  defp present(value) when value in [nil, ""], do: nil
  defp present(value), do: value

  @doc "A page's reading time before it is read, from the script."
  def estimated_seconds(%Entry{} = entry) do
    case Script.for_entry(preload(entry)) do
      nil -> nil
      text -> Script.estimated_seconds(text, entry.language)
    end
  end

  @doc """
  Narrates one entry. Returns `{:ok, media}`, `{:skip, reason}` (already
  narrated, nothing to read, feature off, over the poet's daily cap) or
  `{:error, reason}`. The cap (`DAILY_NARRATION_CAP`, per poet, counted on
  the owner's usage) is the whole cost guard now that any reader of a
  public page can ask for a reading. Option `:force` regenerates even when
  the prose has not changed.
  """
  def generate(%Entry{} = entry, opts \\ []) do
    entry = preload(entry)
    poet = TravelingPoet.Poets.get_poet(entry.poet_id)
    user = poet && Accounts.get_user(poet.user_id)
    text = Script.for_entry(entry)
    current = narration_for(entry.id)

    cond do
      is_nil(poet) or is_nil(user) -> {:skip, :no_poet}
      not configured?() -> {:skip, :off}
      is_nil(text) -> {:skip, :nothing_to_read}
      current && current.content_hash == Script.hash(text) && !opts[:force] -> {:skip, :unchanged}
      not Usage.within_budget?(user, @usage_kind) -> {:skip, :cap}
      true -> narrate(entry, poet, user, text, current)
    end
  end

  defp narrate(entry, poet, user, text, current) do
    hash = Script.hash(text)
    language = entry.language
    model = model(language)
    voice = voice(language)

    with {:ok, %{bytes: bytes, ms: ms}} <-
           request(text,
             instructions: instructions(poet, language),
             model: model,
             voice: voice
           ),
         key = "media/narration-#{entry.id}-#{String.slice(hash, 0, 8)}.mp3",
         {:ok, _} <- storage().upload_content(key, bytes, "audio/mpeg"),
         {:ok, media} <-
           Journal.create_media(%{
             poet_id: poet.id,
             journal_entry_id: entry.id,
             s3_key: key,
             content_type: "audio/mpeg",
             byte_size: byte_size(bytes),
             kind: "narration",
             alt_text: "#{poet.name} reads this page",
             prompt: "#{model} #{voice}",
             content_hash: hash,
             duration_seconds:
               Mp3.duration_seconds(bytes) || Script.estimated_seconds(text, language)
           }) do
      # A forced re-read of unchanged words lands on the same key as the
      # recording it replaces; deleting that object would delete the new one
      # (2026-10-19, entry 684). Drop only the old row then.
      if current, do: replace(current, key)

      Usage.record(user.id, @usage_kind, %{
        metadata: %{
          "media_id" => media.id,
          "entry_id" => entry.id,
          "model" => model,
          "voice" => voice,
          "chars" => String.length(text),
          "ms" => ms
        }
      })

      Phoenix.PubSub.broadcast(
        TravelingPoet.PubSub,
        "poet:#{poet.id}",
        {:narration_ready, entry.id}
      )

      Logger.info("narration: entry #{entry.id} read in #{media.duration_seconds}s (#{ms} ms)")
      {:ok, media}
    end
  end

  @doc "The entry's narration row, if any."
  def narration_for(entry_id) do
    Media
    |> where([m], m.journal_entry_id == ^entry_id and m.kind == "narration")
    |> order_by(desc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Narration rows for many entries: `%{entry_id => media}`."
  def narration_by_entry([]), do: %{}

  def narration_by_entry(entry_ids) do
    Media
    |> where([m], m.journal_entry_id in ^entry_ids and m.kind == "narration")
    |> order_by(asc: :id)
    |> Repo.all()
    |> Map.new(&{&1.journal_entry_id, &1})
  end

  @doc """
  After a revision of a published page: a recording of words that are no
  longer on the page goes, so the ring shows an estimate again and the next
  press reads the new words. Costs nothing; a recording of the same words
  stays. Returns `:dropped`, `:kept` or `:none`.
  """
  def drop_stale(entry_id) when is_integer(entry_id) do
    case narration_for(entry_id) do
      nil ->
        :none

      current ->
        text = Script.for_entry(preload(Journal.get_entry!(entry_id)))

        if is_nil(text) or current.content_hash != Script.hash(text) do
          delete(current)
          :dropped
        else
          :kept
        end
    end
  end

  # The recording a new one replaces: its row always, its object only when
  # the new one was not written over it
  defp replace(%Media{s3_key: key} = old, key), do: Repo.delete(old)
  defp replace(old, _new_key), do: delete(old)

  @doc "Removes a narration: the object and the row."
  def delete(%Media{kind: "narration"} = media) do
    storage().delete_file(media.s3_key)
    Repo.delete(media)
  end

  @doc """
  `{:ok, url}`: a short-lived URL to stream the audio from the bucket, which
  answers range requests the way Safari needs. `{:error, reason}` when the
  signer cannot produce one.
  """
  def stream_url(%Media{kind: "narration"} = media) do
    storage().presigned_get_url(media.s3_key, 3600, "narration.mp3", :inline)
  end

  @doc """
  One speech call: `{:ok, %{bytes, content_type, ms}}` or `{:error, reason}`.
  Options: `:model`, `:voice`, `:instructions`, `:api_key`.
  """
  def request(text, opts \\ []) when is_binary(text) do
    key = Keyword.get(opts, :api_key, Application.get_env(:traveling_poet, :openrouter_api_key))
    model = Keyword.get(opts, :model, model())
    voice = Keyword.get(opts, :voice, voice())

    cond do
      key in [nil, ""] or model in [nil, ""] ->
        {:error, :not_configured}

      true ->
        body =
          %{model: model, input: text, response_format: "mp3"}
          |> put_present(:voice, voice)
          |> put_present(:instructions, Keyword.get(opts, :instructions))

        t0 = System.monotonic_time(:millisecond)

        req_opts =
          [
            json: body,
            headers: [{"authorization", "Bearer #{key}"}],
            receive_timeout: 180_000,
            # the body is audio; Req must not try to decode it
            decode_body: false
          ] ++ Application.get_env(:traveling_poet, :narration_req_options, [])

        case Req.post(@speech_url, req_opts) do
          {:ok, %{status: 200, body: bytes}} when is_binary(bytes) and byte_size(bytes) > 0 ->
            {:ok,
             %{
               bytes: bytes,
               content_type: "audio/mpeg",
               ms: System.monotonic_time(:millisecond) - t0
             }}

          {:ok, %{status: 200}} ->
            {:error, "speech API returned no audio"}

          {:ok, %{status: status, body: resp}} ->
            Logger.warning(
              "Narration: OpenRouter returned #{status} for #{model}: #{inspect(resp, limit: 300)}"
            )

            {:error, "speech API returned #{status}"}

          {:error, reason} ->
            Logger.warning("Narration: request failed: #{inspect(reason)}")
            {:error, "speech API request failed"}
        end
    end
  end

  @doc "How the narrator should read: the poet's temperament, at a diarist's pace. Providers without an instructions field ignore it."
  def instructions(poet, language \\ "en") do
    temperament =
      case poet.personality do
        p when is_binary(p) and p != "" -> " The writer's temperament: #{String.trim(p)}."
        _ -> ""
      end

    "Read this travel journal page#{in_language(language)} in the writer's own voice: unhurried, warm, " <>
      "a little wry, never breathless or salesy. Pause between sections." <> temperament
  end

  defp in_language("en"), do: ""
  defp in_language(language), do: " in " <> TravelingPoet.Locale.name(language)

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp preload(entry) do
    if Ecto.assoc_loaded?(entry.sections), do: entry, else: Repo.preload(entry, :sections)
  end

  defp storage,
    do: Application.get_env(:traveling_poet, :narration_storage, TravelingPoet.Storage.S3)
end
