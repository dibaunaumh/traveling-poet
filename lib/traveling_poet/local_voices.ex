defmodule TravelingPoet.LocalVoices do
  @moduledoc """
  Local voices (card-10, dec-020): when a public poet arrives somewhere a
  reader lives, and that reader said yes when giving their home, the app
  asks them for tips on the poet's behalf. Their answer reaches the poet in
  `/api/agent/context` (`local_voices`), and the poet may put it on a page
  as one `local_tip` section, translated into its own reader's language.

  The app does all the deciding, the poet only writes:

    * who is asked: a reader who opted in (`users.local_voice`) with a home
      within `@radius_km` of where the poet now is, never the poet's own
      reader, asked at most once every `@every_days` days, the one asked
      longest ago first;
    * when: after a published daily run (`after_publish/1`), once per stay;
    * only public poets ask: the question tells a stranger where the poet
      is, which a private poet's map never does;
    * how the tip is credited: by first name, as their poet's companion, or
      anonymously, as they chose (`users.local_voice_credit`). The credit is
      stamped into the section's metadata when the poet puts it
      (`prepare_sections/2`) and rewritten when they change their mind
      (`set_consent/2`); turning it off takes their tips off every page.
      The poet never writes who it is from.

  What a local wrote and where they live are theirs: the change stream
  leaves the table out, and `forget/1` runs on purge.
  """

  use Gettext, backend: TravelingPoetWeb.Gettext

  import Ecto.Query
  require Logger

  alias TravelingPoet.{Geo, Poets, Repo}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Journal.Section
  alias TravelingPoet.LocalVoices.Question
  alias TravelingPoet.Poets.Poet

  @radius_km 30
  # A local is asked at most this often
  @every_days 7
  # An unanswered question is over after this long
  @open_days 5
  # An answer is offered to the poet for this long
  @use_days 10
  @credits ~w(name poet anonymous)

  def radius_km, do: @radius_km
  def open_days, do: @open_days
  def credits, do: @credits

  ## Consent

  @doc """
  Saves whether visiting poets may ask this reader, and how they are
  credited. Their tips already on pages follow at once: re-credited, or
  taken off when they say no.
  """
  def set_consent(%User{} = user, attrs) do
    with {:ok, updated} <-
           user
           |> User.changeset(Map.take(attrs, [:local_voice, :local_voice_credit]))
           |> Repo.update() do
      if updated.local_voice, do: refresh_credits(updated), else: forget(updated)
      {:ok, updated}
    end
  end

  @doc "Takes every tip this reader gave off the pages it is on. Their questions stay."
  def forget(%User{} = user) do
    {ids, sections} = tip_sections(user.id)

    if sections != [] do
      Repo.delete_all(from(s in Section, where: s.id in ^Enum.map(sections, & &1.id)))
    end

    Repo.update_all(from(q in Question, where: q.id in ^ids), set: [used_entry_id: nil])
    :ok
  end

  defp refresh_credits(user) do
    {_ids, sections} = tip_sections(user.id)

    for s <- sections do
      question = Repo.get(Question, s.metadata["local_question_id"])

      s
      |> Ecto.Changeset.change(metadata: stamp(s.metadata, credit(user, question)))
      |> Repo.update!()
    end

    :ok
  end

  # The local_tip sections that carry this reader's answers
  defp tip_sections(user_id) do
    used =
      from(q in Question,
        where: q.user_id == ^user_id and not is_nil(q.used_entry_id),
        select: {q.id, q.used_entry_id}
      )
      |> Repo.all()

    ids = Enum.map(used, &elem(&1, 0))

    sections =
      from(s in Section,
        where: s.kind == "local_tip" and s.journal_entry_id in ^Enum.map(used, &elem(&1, 1))
      )
      |> Repo.all()
      |> Enum.filter(&(&1.metadata["local_question_id"] in ids))

    {ids, sections}
  end

  ## Asking

  @doc """
  After a published daily run: asks one local, when this poet has just
  reached somewhere one lives and has not asked this stay. Returns the
  question or nil.
  """
  def after_publish(%Poet{id: id}) do
    case Poets.get_poet(id) do
      nil -> nil
      poet -> maybe_ask(poet, DateTime.utc_now())
    end
  end

  @doc false
  def maybe_ask(%Poet{} = poet, now) do
    with true <- poet.is_public and poet.status == "active",
         true <- is_number(poet.current_lat) and is_binary(poet.current_place_name),
         false <- asked_this_stay?(poet),
         %User{} = local <- pick_local(poet, now),
         {:ok, question} <- create(poet, local) do
      question
    else
      _ -> nil
    end
  end

  defp asked_this_stay?(poet) do
    since = poet.arrived_at && DateTime.to_naive(poet.arrived_at)

    Question
    |> where(poet_id: ^poet.id)
    |> then(&if since, do: where(&1, [q], q.inserted_at >= ^since), else: &1)
    |> Repo.exists?()
  end

  @doc "The local to ask, or nil: nearby, willing, and not asked lately."
  def pick_local(%Poet{} = poet, now \\ DateTime.utc_now()) do
    recent = now |> DateTime.add(-@every_days, :day) |> DateTime.to_naive()

    last_asked =
      from(q in Question, group_by: q.user_id, select: {q.user_id, max(q.inserted_at)})
      |> Repo.all()
      |> Map.new()

    from(u in User,
      where: u.local_voice and not is_nil(u.home_lat) and not is_nil(u.home_lng),
      where: u.id != ^poet.user_id
    )
    |> Repo.all()
    |> Enum.filter(fn u ->
      Geo.distance_km(poet.current_lat, poet.current_lng, u.home_lat, u.home_lng) <= @radius_km
    end)
    |> Enum.reject(fn u ->
      at = last_asked[u.id]
      at && NaiveDateTime.compare(at, recent) != :lt
    end)
    |> Enum.shuffle()
    |> Enum.sort_by(&(last_asked[&1.id] || ~N[2000-01-01 00:00:00]), NaiveDateTime)
    |> List.first()
  end

  defp create(poet, local) do
    with {:ok, question} <-
           %Question{}
           |> Question.changeset(%{
             poet_id: poet.id,
             user_id: local.id,
             place_name: poet.current_place_name
           })
           |> Repo.insert() do
      Logger.info(
        "LocalVoices: poet #{poet.id} asks user #{local.id} about #{question.place_name}"
      )

      Phoenix.PubSub.broadcast(
        TravelingPoet.PubSub,
        "local_voices",
        {:local_question, local.id, question.id}
      )

      {:ok, question}
    end
  end

  @doc """
  What the local is told, on every channel, in the current locale. Pure:
  takes the question with its poet. `path` is the answer form.
  """
  def notice(%Question{poet: %Poet{} = poet} = q) do
    %{
      title:
        dgettext("notify", "%{poet} is in %{place}",
          poet: poet.name,
          place: short_place(q.place_name)
        ),
      body:
        dgettext(
          "notify",
          "You live nearby. Is there a place, a dish or a corner of town you would tell them about?"
        ),
      path: "/locals/#{q.id}"
    }
  end

  ## Answering

  def get(id), do: Repo.get(Question, id) |> Repo.preload(:poet)

  @doc "The question, when it was put to this reader."
  def get_for_user(user_id, id) do
    case Repo.get_by(Question, id: id, user_id: user_id) do
      nil -> nil
      q -> Repo.preload(q, :poet)
    end
  end

  @doc "Whether the question can still be answered."
  def open?(question, now \\ DateTime.utc_now())

  def open?(%Question{status: "open", inserted_at: at}, now) do
    NaiveDateTime.diff(DateTime.to_naive(now), at, :day) < @open_days
  end

  def open?(_question, _now), do: false

  @doc "Questions this reader can still answer, newest first."
  def open_for(user_id) do
    from(q in Question, where: q.user_id == ^user_id and q.status == "open")
    |> order_by(desc: :inserted_at)
    |> preload(:poet)
    |> Repo.all()
    |> Enum.filter(&open?/1)
  end

  def answer(%Question{} = question, text) do
    if open?(question) do
      question |> Question.answer_changeset(%{answer: text}) |> Repo.update()
    else
      {:error, :closed}
    end
  end

  def decline(%Question{} = question) do
    question |> Ecto.Changeset.change(status: "declined") |> Repo.update()
  end

  ## The poet's side

  @doc """
  What the poet is handed in its context: answers from locals, not yet on
  a page, given in the last `@use_days` days.
  """
  def payload(%Poet{id: poet_id}) do
    since = DateTime.utc_now() |> DateTime.add(-@use_days, :day) |> DateTime.truncate(:second)

    from(q in Question,
      join: u in assoc(q, :user),
      where: q.poet_id == ^poet_id and q.status == "answered" and is_nil(q.used_entry_id),
      where: q.answered_at >= ^since and u.local_voice,
      order_by: [desc: q.answered_at]
    )
    |> Repo.all()
    |> Enum.map(fn q ->
      %{
        local_question_id: q.id,
        place: q.place_name,
        answered_on: DateTime.to_date(q.answered_at),
        tips: q.answer
      }
    end)
  end

  @doc """
  Checks the `local_tip` sections of a put: each must name, in
  `metadata.local_question_id`, an answer this poet was given and that is
  not already on another page. Those get the credit stamped in; the rest
  are left off. Returns `{sections, refused, question_ids}`.
  """
  def prepare_sections(%Poet{} = poet, sections, entry_id) do
    Enum.reduce(sections, {[], [], []}, fn s, {kept, refused, ids} ->
      if field(s, "kind") == "local_tip" do
        case usable(poet, question_id(s), entry_id) do
          %Question{} = q ->
            local = Repo.get(User, q.user_id)

            s =
              put_field(
                s,
                "metadata",
                stamp(%{}, credit(local, q)) |> Map.put("local_question_id", q.id)
              )

            {[s | kept], refused, [q.id | ids]}

          nil ->
            {kept, [question_id(s) | refused], ids}
        end
      else
        {[s | kept], refused, ids}
      end
    end)
    |> then(fn {kept, refused, ids} -> {Enum.reverse(kept), Enum.reverse(refused), ids} end)
  end

  @doc "Marks the answers as on this page."
  def mark_used([], _entry_id), do: :ok

  def mark_used(ids, entry_id) do
    Repo.update_all(from(q in Question, where: q.id in ^ids), set: [used_entry_id: entry_id])
    :ok
  end

  defp usable(poet, id, entry_id) when is_integer(id) do
    from(q in Question,
      join: u in assoc(q, :user),
      where: q.id == ^id and q.poet_id == ^poet.id and q.status == "answered" and u.local_voice,
      where: is_nil(q.used_entry_id) or q.used_entry_id == ^entry_id
    )
    |> Repo.one()
  end

  defp usable(_poet, _id, _entry_id), do: nil

  defp question_id(s) do
    case field(s, "metadata") do
      %{} = m ->
        case m["local_question_id"] || m[:local_question_id] do
          id when is_integer(id) -> id
          id when is_binary(id) -> with({n, ""} <- Integer.parse(id), do: n, else: (_ -> nil))
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp field(s, key) when is_map(s), do: Map.get(s, key) || Map.get(s, String.to_atom(key))
  defp field(_s, _key), do: nil

  defp put_field(s, key, value) do
    s |> Map.delete(String.to_atom(key)) |> Map.put(key, value)
  end

  ## Credit

  @doc "How a tip is credited, from the local's current choice. Stored in the section."
  def credit(%User{} = local, %Question{} = q) do
    base = %{"style" => local.local_voice_credit, "place" => short_place(q.place_name)}

    case local.local_voice_credit do
      "name" ->
        Map.put(base, "name", first_name(local.name))

      "poet" ->
        case Poets.get_poet_by_user(local.id) do
          %Poet{} = own ->
            base
            |> Map.put("poet_name", own.name)
            |> Map.put("poet_slug", own.is_public && own.slug)

          nil ->
            %{base | "style" => "anonymous"}
        end

      _ ->
        %{base | "style" => "anonymous"}
    end
  end

  defp stamp(metadata, credit), do: Map.put(metadata || %{}, "credit", credit)

  @doc "The credit line under a tip, in the current locale."
  def credit_text(%{"style" => "name", "name" => name, "place" => place})
      when is_binary(name) and name != "",
      do: dgettext("notebook", "From %{name}, who lives in %{place}", name: name, place: place)

  def credit_text(%{"style" => "poet", "poet_name" => poet, "place" => place})
      when is_binary(poet),
      do:
        dgettext("notebook", "From %{poet}'s companion, who lives in %{place}",
          poet: poet,
          place: place
        )

  def credit_text(%{"place" => place}),
    do: dgettext("notebook", "From a reader who lives in %{place}", place: place)

  def credit_text(_), do: dgettext("notebook", "From a reader who lives here")

  @doc "The place as a reader says it: \"Lisbon\" for \"Lisbon, Portugal\"."
  def short_place(nil), do: nil
  def short_place(name), do: name |> String.split(",") |> hd() |> String.trim()

  defp first_name(nil), do: nil
  defp first_name(name), do: name |> String.split() |> List.first()
end
