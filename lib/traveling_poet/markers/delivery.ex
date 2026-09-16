defmodule TravelingPoet.Markers.Delivery do
  @moduledoc """
  Turns a reader's pending markers into one `/revise-entry` turn for the poet,
  once the reader has gone quiet.

  Why wait: a marker is dropped mid-read. Firing on each one would have the
  poet rewriting the page under the reader's eyes, and would spend a turn per
  marker instead of one per sitting. So an entry is due only when its newest
  pending marker is older than `quiet_minutes/0`.

  State lives entirely in the database, the `FirstEntry` shape: `due/1` is a
  pure query, `claim/2` records the attempt and stamps `sent_at` BEFORE the
  turn is dispatched (a crash then loses one digest rather than looping), and
  `dispatch/2` fires `AgentSession`. `sweep/1` chains them and is what the
  watchdog calls.

  The trigger goes over channel "system", which hides it from the chat
  sidebar; the poet's short reply stays visible, so the reader learns that the
  feedback landed. A busy guard keeps a revision from stacking on a daily run,
  a first-entry ritual, or a live chat turn: there is no lock on a sprite and
  two concurrent turns interleave their streams.
  """

  require Logger

  import Ecto.Query

  alias TravelingPoet.{Accounts, AgentSession, Credits, Journal, Markers, Repo, Usage}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Journal.{Entry, Marker}
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Usage.UsageEvent

  @trigger "/revise-entry"
  @attempt_kind "marker_revision_attempt"
  # Anything that holds the sprite in a long turn.
  @busy_kinds ~w(daily_run_attempt first_entry_attempt marker_revision_attempt book_compose_attempt)
  @busy_window_minutes 15
  @chat_window_minutes 5
  @reply_timeout_ms 10 * 60 * 1000

  def attempt_kind, do: @attempt_kind

  def quiet_minutes, do: Application.get_env(:traveling_poet, :marker_quiet_minutes, 15)

  @doc """
  Entries whose markers are ready to go: `[%{user, poet, entry, markers}]`.
  Pure selection, no writes.
  """
  def due(now \\ DateTime.utc_now()) do
    cutoff = now |> DateTime.add(-quiet_minutes(), :minute) |> DateTime.to_naive()

    Markers.pending_by_entry()
    |> Enum.filter(fn {_id, newest, _markers} -> NaiveDateTime.compare(newest, cutoff) != :gt end)
    |> Enum.flat_map(fn {entry_id, _newest, markers} ->
      # `sprite_provisioned` is the real gate (same reasoning as FirstEntry): a
      # poet left on "provisioning" by a failed status flip has a working
      # sprite. Paused and errored poets stay out.
      with %Entry{status: "published"} = entry <- Repo.get(Entry, entry_id),
           %Poet{status: status} = poet when status in ["active", "provisioning"] <-
             Repo.get(Poet, entry.poet_id),
           %User{sprite_provisioned: true} = user <- Accounts.get_user(poet.user_id),
           false <- busy?(user.id, now),
           false <- Credits.exhausted?(user, poet),
           true <- Usage.within_budget?(user, @attempt_kind) do
        [%{user: user, poet: poet, entry: entry, markers: markers}]
      else
        _ -> []
      end
    end)
  end

  @doc """
  Records the attempt, stamps the markers sent, and returns the digest to
  send. No network.
  """
  def claim(%{user: user, poet: poet, entry: entry, markers: markers}, now \\ DateTime.utc_now()) do
    {:ok, _} =
      Usage.record(user.id, @attempt_kind, %{
        metadata: %{"entry_id" => entry.id, "markers" => length(markers)}
      })

    Markers.mark_sent(Enum.map(markers, & &1.id), now)

    latest? =
      case Journal.latest_published_entry(poet.id) do
        %Entry{id: id} -> id == entry.id
        _ -> false
      end

    {:ok, digest_message(poet, entry, markers, latest?)}
  end

  @doc "Fires the turn in a task and logs how it ended."
  def dispatch(user, message) do
    Task.start(fn ->
      Logger.info("Markers.Delivery: firing #{@trigger} for user #{user.id}")

      case AgentSession.run(user, message,
             channel: "system",
             reply_timeout_ms: @reply_timeout_ms
           ) do
        {:ok, _reply} ->
          Logger.info("Markers.Delivery: user #{user.id} revision turn finished")

        {:timeout, _partial} ->
          Logger.warning("Markers.Delivery: user #{user.id} went silent mid-revision")

        {:error, reason} ->
          Logger.warning("Markers.Delivery: user #{user.id} revision failed: #{inspect(reason)}")
      end
    end)
  end

  @doc "due |> claim |> dispatch. Called by the watchdog on its tick."
  def sweep(now \\ DateTime.utc_now()) do
    now
    |> due()
    |> Enum.map(fn d ->
      {:ok, message} = claim(d, now)
      dispatch(d.user, message)
      {d.poet.name, :started}
    end)
  end

  @doc """
  The message the poet receives. One line per marker, in page order, each
  spelling out what the marker asks so the agent never has to guess.
  """
  def digest_message(poet, entry, markers, latest?) do
    date = Date.to_iso8601(entry.entry_date)
    title = if entry.title, do: ~s("#{entry.title}"), else: "the entry"

    scope =
      if latest? do
        "#{title} (#{date}) is your latest published entry: revise it."
      else
        "#{title} (#{date}) is not your latest entry: do not rewrite it. " <>
          "Take the feedback as learning only."
      end

    lines =
      markers
      |> Enum.sort_by(&{&1.section_position || 1_000_000, &1.id})
      |> Enum.map(&marker_line/1)

    Enum.join(
      [
        "#{@trigger} #{date}",
        scope,
        "#{poet.name}'s companion marked these passages. Load the revise-entry skill and follow it.",
        ""
      ] ++ lines,
      "\n"
    )
  end

  # "Other feedback" carries the companion's own words; quote them verbatim.
  defp marker_line(%Marker{kind: "other"} = m) do
    note = if m.note in [nil, ""], do: "(they left no note)", else: ~s("#{m.note}")
    "- [#{Marker.label("other")}] #{where(m)} -> your companion wrote: #{note}"
  end

  defp marker_line(%Marker{} = m) do
    spec = Marker.spec(m.kind)
    "- [#{spec.label}] #{where(m)} -> #{spec.ask}"
  end

  defp where(%Marker{target: "text"} = m) do
    ~s(#{section_name(m)}: "#{m.quote}")
  end

  defp where(%Marker{target: "section"} = m) do
    "#{section_name(m)} (the whole section)"
  end

  defp where(%Marker{target: "illustration"} = m) do
    "the illustration (media #{m.media_id})"
  end

  defp section_name(%Marker{section_kind: nil}), do: "the entry"
  defp section_name(%Marker{section_kind: kind}), do: "the #{kind} section"

  # -- guards --

  @doc """
  Whether a long turn (a daily run, a first entry, a revision, a book
  composition) or a live chat turn is recent enough that another turn would
  interleave with it. There is no lock on a sprite.
  """
  def busy?(user_id, now \\ DateTime.utc_now()) do
    long_cutoff = DateTime.add(now, -@busy_window_minutes, :minute)
    chat_cutoff = DateTime.add(now, -@chat_window_minutes, :minute)

    UsageEvent
    |> where(user_id: ^user_id)
    |> where(
      [e],
      (e.kind in ^@busy_kinds and e.occurred_at >= ^long_cutoff) or
        (e.kind == "chat_turn" and e.occurred_at >= ^chat_cutoff)
    )
    |> Repo.exists?()
  end
end
