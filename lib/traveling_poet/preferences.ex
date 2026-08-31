defmodule TravelingPoet.Preferences do
  @moduledoc """
  What the poet has learned about its companion, and how it learns it.

  The problem this exists to solve: a user who stops enjoying the journal goes
  quiet rather than opening settings. In production, 35 entries produced 5
  reactions — all "love", all from the developer's own accounts — while real
  steering ("look for american stupid things") happened in chat and evaporated
  after a single turn. So preferences are captured from wherever the user
  actually expresses them, persisted, and folded into a profile the poet reads
  on every run.

  Two rules keep automatic tuning safe:

    * **Decay.** A preference confirmed once is a nudge, not a law: a
      `weight: 1` row stops counting after `stale_after_days/0`. Only
      repetition hardens into a standing instruction. Without this, a single
      mis-tap narrows the poet forever and the only cure is a settings page
      most users never open.
    * **Dismissal is sticky against inference.** Removing a preference is a
      statement. `tap` and `settings` may bring one back — the user changed
      their mind — but `chat` and `reaction` may not, so the poet cannot
      quietly re-learn next week exactly what was thrown out today.
  """

  import Ecto.Query

  alias TravelingPoet.Preferences.{Cadence, EntryPrompt, Preference, Prompts}
  alias TravelingPoet.Repo

  # Beyond this, a preference confirmed only once no longer steers the poet.
  @stale_after_days 30
  # The agent reads this list every run; long lists dilute rather than inform.
  @profile_limit 12

  def stale_after_days, do: @stale_after_days
  def profile_limit, do: @profile_limit

  @doc """
  Records a preference, merging with what is already known.

  Same key, same polarity → confirmed again (weight up). Same key, opposite
  polarity → the user changed their mind: the row flips in place, weight
  resets, and the previous stance is kept in `evidence["previous"]` so the
  panel can explain itself.

  Attrs: `:label` (required), `:dimension`, `:polarity`, `:source`, and
  optionally `:key`, `:evidence`.
  """
  def record(poet_id, attrs) do
    attrs = normalize(attrs)

    case Repo.get_by(Preference, poet_id: poet_id, key: attrs.key) do
      nil -> insert_new(poet_id, attrs)
      existing -> merge(existing, attrs)
    end
  end

  defp insert_new(poet_id, attrs) do
    %Preference{}
    |> Preference.changeset(%{
      poet_id: poet_id,
      key: attrs.key,
      label: attrs.label,
      dimension: attrs.dimension,
      polarity: attrs.polarity,
      source: attrs.source,
      evidence: attrs.evidence,
      weight: 1,
      status: "active",
      last_confirmed_at: now()
    })
    |> Repo.insert()
  end

  defp merge(existing, attrs) do
    cond do
      # The user removed this; only their own deliberate act brings it back.
      existing.status == "dismissed" and attrs.source not in Preference.explicit_sources() ->
        {:ok, existing}

      existing.polarity != attrs.polarity ->
        existing
        |> Preference.changeset(%{
          polarity: attrs.polarity,
          label: attrs.label,
          source: attrs.source,
          status: "active",
          weight: 1,
          last_confirmed_at: now(),
          evidence:
            Map.put(attrs.evidence, "previous", %{
              "polarity" => existing.polarity,
              "label" => existing.label
            })
        })
        |> Repo.update()

      true ->
        existing
        |> Preference.changeset(%{
          weight: existing.weight + 1,
          status: "active",
          last_confirmed_at: now(),
          # A user's own words outrank an inferred paraphrase.
          label: prefer_explicit_label(existing, attrs),
          source: stronger_source(existing.source, attrs.source)
        })
        |> Repo.update()
    end
  end

  defp prefer_explicit_label(existing, attrs) do
    if attrs.source in Preference.explicit_sources(), do: attrs.label, else: existing.label
  end

  defp stronger_source(existing, incoming) do
    if incoming in Preference.explicit_sources(), do: incoming, else: existing
  end

  @doc """
  What the poet should act on: active preferences that are still current,
  strongest first. This is the single source of truth for both the settings
  panel and the agent's context, so the two can never disagree.
  """
  def profile(poet_id, now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@stale_after_days, :day)

    poet_id
    |> active_query()
    |> Repo.all()
    |> Enum.reject(&stale?(&1, cutoff))
    |> Enum.sort_by(&{&1.weight, DateTime.to_unix(confirmed_at(&1))}, :desc)
    |> Enum.take(@profile_limit)
  end

  # Confirmed once and long ago: it was a passing mood, not a standing wish.
  defp stale?(%{weight: weight} = pref, cutoff) when weight <= 1 do
    DateTime.compare(confirmed_at(pref), cutoff) == :lt
  end

  defp stale?(_pref, _cutoff), do: false

  defp confirmed_at(%{last_confirmed_at: nil, inserted_at: inserted_at}),
    do: DateTime.from_naive!(inserted_at, "Etc/UTC")

  defp confirmed_at(%{last_confirmed_at: at}), do: at

  @doc "Everything active, including stale rows — what the settings panel lists."
  def list_active(poet_id), do: poet_id |> active_query() |> Repo.all()

  @doc "Removed preferences, so the panel can offer them back."
  def list_dismissed(poet_id) do
    Preference
    |> where(poet_id: ^poet_id, status: "dismissed")
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  defp active_query(poet_id) do
    Preference
    |> where(poet_id: ^poet_id, status: "active")
    |> order_by(desc: :weight, desc: :last_confirmed_at)
  end

  @doc "The user removes a preference. Kept, not deleted — the row is what blocks re-learning."
  def dismiss(%Preference{} = pref) do
    pref |> Preference.changeset(%{status: "dismissed"}) |> Repo.update()
  end

  @doc "The user brings one back."
  def restore(%Preference{} = pref) do
    pref
    |> Preference.changeset(%{status: "active", source: "settings", last_confirmed_at: now()})
    |> Repo.update()
  end

  @doc "The user rewrites it in their own words, which outranks anything inferred."
  def relabel(%Preference{} = pref, label) do
    pref
    |> Preference.changeset(%{label: label, source: "settings", last_confirmed_at: now()})
    |> Repo.update()
  end

  def get(poet_id, id) do
    Repo.get_by(Preference, id: id, poet_id: poet_id)
  end

  @doc "Compact form for the agent's context payload."
  def profile_payload(poet_id, now \\ DateTime.utc_now()) do
    poet_id
    |> profile(now)
    |> Enum.map(
      &%{
        label: &1.label,
        dimension: &1.dimension,
        polarity: &1.polarity,
        weight: &1.weight,
        source: &1.source,
        last_confirmed_at: &1.last_confirmed_at
      }
    )
  end

  @doc """
  Questions the reader has answered lately, with what they chose — so the poet
  can see the exchange, not just the conclusion.
  """
  def recent_answers(poet_id, since) do
    from(p in EntryPrompt,
      join: e in TravelingPoet.Journal.Entry,
      on: e.id == p.journal_entry_id,
      where: e.poet_id == ^poet_id and not is_nil(p.answered_at) and p.answered_at >= ^since,
      order_by: [desc: p.answered_at],
      select: %{
        entry_date: e.entry_date,
        question: p.question,
        answer_option_id: p.answer_option_id,
        answered_at: p.answered_at
      }
    )
    |> Repo.all()
  end

  @doc "What the poet must not propose again — the user already said no."
  def dismissed_payload(poet_id) do
    poet_id
    |> list_dismissed()
    |> Enum.map(&%{label: &1.label, dimension: &1.dimension, polarity: &1.polarity})
  end

  defp normalize(attrs) do
    attrs = Map.new(attrs)
    label = attrs |> Map.fetch!(:label) |> to_string() |> String.trim()
    dimension = Map.get(attrs, :dimension, "topic")

    %{
      label: label,
      dimension: dimension,
      polarity: Map.get(attrs, :polarity, "seek"),
      source: Map.get(attrs, :source, "tap"),
      evidence: Map.get(attrs, :evidence, %{}),
      key: Map.get(attrs, :key) || derive_key(dimension, label)
    }
  end

  @doc """
  Groups a preference by what it is about, ignoring how it was phrased, so a
  later answer to the same question replaces the earlier one.
  """
  def derive_key(dimension, label) do
    slug =
      label
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    "#{dimension}:#{slug}"
  end

  ## The question under an entry

  @doc """
  The prompt for this entry: an existing one, or a new one when the cadence
  says it's time. Returns `nil` when the reader should be left alone.

  The prompt row is created on first render rather than at publish time, so an
  entry nobody opens never manufactures a question, and the question reflects
  what the poet knows at the moment of reading.
  """
  def prompt_for_entry(poet, entry, now \\ DateTime.utc_now()) do
    case Cadence.prompt_for(entry.id) do
      %EntryPrompt{} = existing ->
        existing

      nil ->
        case Cadence.ask?(poet, entry, now) do
          {true, reason} -> create_prompt(poet, entry, reason)
          false -> nil
        end
    end
  end

  defp create_prompt(poet, entry, reason) do
    attrs =
      case Cadence.question_kind(reason) do
        :broad -> Prompts.broad_check_in(entry)
        :narrow -> Prompts.default_for(entry, profile(poet.id))
      end

    %EntryPrompt{}
    |> EntryPrompt.changeset(%{
      journal_entry_id: entry.id,
      question: attrs.question,
      options: %{"items" => attrs.options},
      source: attrs.source
    })
    |> Repo.insert()
    |> case do
      {:ok, prompt} -> prompt
      # Raced with another tab; the existing row wins.
      {:error, _} -> Cadence.prompt_for(entry.id)
    end
  end

  @doc """
  Records the reader's tap: stamps the prompt and turns the chosen option into
  a preference, in one transaction so a half-answer can't exist.
  """
  def answer_prompt(%EntryPrompt{} = prompt, option_id, poet_id, entry \\ nil) do
    case Enum.find(EntryPrompt.items(prompt), &(&1["id"] == option_id)) do
      nil ->
        {:error, :unknown_option}

      option ->
        Repo.transaction(fn ->
          {:ok, prompt} =
            prompt
            |> EntryPrompt.changeset(%{answered_at: now(), answer_option_id: option_id})
            |> Repo.update()

          {:ok, preference} =
            record(poet_id, %{
              label: option["label"],
              key: option["key"],
              dimension: option["dimension"],
              polarity: option["polarity"],
              source: "tap",
              evidence:
                %{"question" => prompt.question, "answer" => option["label"]}
                |> maybe_put_entry(entry)
            })

          {prompt, preference}
        end)
    end
  end

  defp maybe_put_entry(evidence, nil), do: evidence

  defp maybe_put_entry(evidence, entry),
    do: Map.put(evidence, "entry_date", to_string(entry.entry_date))

  @doc "The reader changes their mind straight after tapping."
  def undo_answer(%EntryPrompt{} = prompt, poet_id) do
    Repo.transaction(fn ->
      option = EntryPrompt.answered_option(prompt)

      if option do
        case Repo.get_by(Preference, poet_id: poet_id, key: option["key"]) do
          nil -> :ok
          pref -> dismiss(pref)
        end
      end

      {:ok, prompt} =
        prompt
        |> EntryPrompt.changeset(%{answered_at: nil, answer_option_id: nil})
        |> Repo.update()

      prompt
    end)
  end

  @doc "The reader waves the question away. Counts as a signal: ask less."
  def dismiss_prompt(%EntryPrompt{} = prompt) do
    prompt |> EntryPrompt.changeset(%{dismissed_at: now()}) |> Repo.update()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
