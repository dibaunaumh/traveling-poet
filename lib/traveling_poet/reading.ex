defmodule TravelingPoet.Reading do
  @moduledoc """
  Reading signals for the taste profile (card-49): how long the owner of a
  journal spends on each paragraph of it. The browser measures (the
  `ReadingTime` hook on the owner's journal only) and sends time per
  paragraph key; this keeps only keys that are paragraphs of that entry, so
  a stale page or a made-up key records nothing.

  Owner only: a public reader is never measured. `users.reading_signals`
  (on by default, a switch in Settings) stops it, and turning it off forgets
  what was kept.
  """

  import Ecto.Query

  alias TravelingPoet.Repo
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Journal.{Entry, Paragraphs, Section}
  alias TravelingPoet.Reading.ParagraphRead

  # One report covers at most this much time per paragraph: the hook sends
  # every 30 seconds and stops counting when the reader goes idle, so more
  # is a tab left open, not reading.
  @max_ms_per_report 120_000

  def max_ms_per_report, do: @max_ms_per_report

  @doc """
  Adds `reads` (`%{key => ms}`) to `user`'s time on `entry` for `today`.
  Returns the number of paragraphs recorded. Records nothing when the user
  turned reading signals off or the entry is not theirs.
  """
  def record(user, entry, reads, today \\ Date.utc_today())

  def record(%User{reading_signals: false}, _entry, _reads, _today), do: 0

  def record(%User{} = user, %Entry{} = entry, reads, today) when is_map(reads) do
    if owner?(user, entry) do
      paragraphs = entry_paragraphs(entry)
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()

      rows =
        Enum.flat_map(reads, fn {key, ms} ->
          case {Map.get(paragraphs, key), clamp(ms)} do
            {nil, _} ->
              []

            {_, 0} ->
              []

            {p, ms} ->
              [
                %{
                  user_id: user.id,
                  journal_entry_id: entry.id,
                  key: key,
                  read_on: today,
                  ms: ms,
                  chars: String.length(p.text),
                  inserted_at: now,
                  updated_at: now
                }
              ]
          end
        end)

      # The day's row grows: a second visit adds its time to the first.
      {count, _} =
        Repo.insert_all(ParagraphRead, rows,
          on_conflict:
            from(r in ParagraphRead,
              update: [
                set: [
                  ms: fragment("? + excluded.ms", r.ms),
                  updated_at: fragment("excluded.updated_at")
                ]
              ]
            ),
          conflict_target: [:user_id, :journal_entry_id, :key, :read_on]
        )

      count
    else
      0
    end
  end

  def record(_user, _entry, _reads, _today), do: 0

  @doc "Forgets every reading signal kept for `user`."
  def forget(%User{id: id}) do
    {count, _} = Repo.delete_all(from r in ParagraphRead, where: r.user_id == ^id)
    count
  end

  @doc "The user's reading rows, newest day first (for the profile and tests)."
  def list(%User{id: id}) do
    Repo.all(
      from r in ParagraphRead, where: r.user_id == ^id, order_by: [desc: r.read_on, asc: r.id]
    )
  end

  defp owner?(user, entry) do
    Repo.exists?(
      from p in TravelingPoet.Poets.Poet, where: p.id == ^entry.poet_id and p.user_id == ^user.id
    )
  end

  defp entry_paragraphs(entry) do
    Section
    |> where(journal_entry_id: ^entry.id)
    |> Repo.all()
    |> Paragraphs.of_sections()
    |> Map.new(&{&1.key, &1})
  end

  defp clamp(ms) when is_integer(ms), do: ms |> max(0) |> min(@max_ms_per_report)
  defp clamp(ms) when is_float(ms), do: clamp(round(ms))
  defp clamp(_), do: 0
end
