defmodule TravelingPoet.Books do
  @moduledoc """
  The journal as a book.

  The home page promises that both ways of travelling "end up in the same
  notebook"; this is where that notebook can be taken off the shelf whole.
  The context does the reading (every published day, the poet's path) and
  hands it to `Books.Manuscript`, which is pure and decides the chapters.

  A composed edition is the poet's own words around the journal: a
  dedication, a foreword, an opener for each chapter, an epilogue and a few
  lines quoted from its own pages. It is one paid agent turn
  (`request_composition/2`), charged up front and refunded unless the words
  actually landed (`Books.Composer.finish/2`). The poet can write matter
  only while its edition is open, so chat cannot buy a free one.
  """

  import Ecto.Query
  require Logger

  alias TravelingPoet.{Accounts, Credits, Journal, Poets, Repo, Usage}
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Books.{Composer, Edition, Manuscript, Matter, Pdf, PdfRenderer}
  alias TravelingPoet.Journal.EntryBundle
  alias TravelingPoet.Markers.Delivery

  @attempt_kind "book_compose_attempt"
  # A turn is given 15 minutes; an edition still open after this is stale
  # (the app restarted mid-turn, the socket died) and is settled on read.
  @stale_after_minutes 30

  @doc """
  The whole published journal as chapters of days. No 60-entry cap: a book
  is the one place the journey must be complete. Options go to
  `Manuscript.build/4`.
  """
  @spec manuscript(map, keyword) :: Manuscript.t()
  def manuscript(poet, opts \\ []) do
    entries = Journal.list_entries(poet.id, status: "published", limit: :all, order: :asc)
    stays = Poets.list_path_points(poet.id)
    bundles = EntryBundle.load_many(entries, stays: stays)

    Manuscript.build(poet, bundles, stays, opts)
  end

  ## Editions

  def get_edition(id), do: Repo.get(Edition, id)

  @doc "The newest edition for this poet, settling it first if it went stale."
  def current_edition(%{id: poet_id}) do
    Edition
    |> where(poet_id: ^poet_id)
    |> order_by(desc: :id)
    |> limit(1)
    |> Repo.one()
    |> reap_if_stale()
  end

  @doc "The newest edition whose matter landed: what the book prints."
  def latest_ready_edition(%{id: poet_id}) do
    Edition
    |> where(poet_id: ^poet_id, status: "ready")
    |> order_by(desc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "The edition the poet may write into right now, if any."
  def open_edition(%{id: poet_id}) do
    Edition
    |> where(poet_id: ^poet_id, status: "composing")
    |> order_by(desc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Whether a composition turn is running for this poet (the scheduler waits for it)."
  def composing?(poet), do: match?(%Edition{status: "composing"}, current_edition(poet))

  @doc "Milli-credits a composition of this journey costs."
  def compose_cost(%Manuscript{chapters: chapters}),
    do: Credits.book_compose_cost(length(chapters))

  @doc """
  Whether a composition may start, and the reason when not. The reasons are
  shown to the companion as they are.
  """
  def compose_blocker(%User{} = user, poet, %Manuscript{} = manuscript) do
    cost = compose_cost(manuscript)

    cond do
      manuscript.chapters == [] -> {:blocked, :empty}
      not user.sprite_provisioned -> {:blocked, :no_sprite}
      composing?(poet) -> {:blocked, :already_composing}
      not Usage.within_budget?(user, @attempt_kind) -> {:blocked, :daily_cap}
      not Credits.can_afford?(user, cost) -> {:blocked, :insufficient_credits}
      Delivery.busy?(user.id) -> {:blocked, :poet_busy}
      true -> :ok
    end
  end

  @doc """
  Opens a composed edition and sets the poet to write it: records the
  attempt, opens the edition, charges it, then fires the turn (in the
  background unless configured off, as in test). A charge that fails closes
  the edition again, so nothing is left open and unpaid.
  """
  def request_composition(%User{} = user, poet) do
    manuscript = manuscript(poet)

    with :ok <- compose_blocker(user, poet, manuscript) do
      cost = compose_cost(manuscript)
      chapters = length(manuscript.chapters)
      {:ok, _attempt} = Usage.record(user.id, @attempt_kind, %{metadata: %{"poet_id" => poet.id}})

      {:ok, edition} =
        %Edition{}
        |> Edition.changeset(%{
          poet_id: poet.id,
          status: "composing",
          chapter_count: chapters,
          credits_charged: if(user.quota_exempt, do: 0, else: cost)
        })
        |> Repo.insert()

      case Credits.debit_book_compose(user, edition.id, cost, chapters) do
        {:ok, _} ->
          broadcast_updated(user.id, edition)
          maybe_dispatch(user, edition)
          {:ok, edition}

        {:error, reason} ->
          Repo.delete(edition)
          Logger.warning("Books: composition for poet #{poet.id} not charged: #{inspect(reason)}")
          {:blocked, :insufficient_credits}
      end
    end
  end

  @doc """
  Applies a put from the poet to its open edition. `{:ok, edition, report}`,
  or `{:error, :not_composing}` when no paid composition is open.
  """
  def put_matter(poet, params) when is_map(params) do
    case open_edition(poet) do
      nil ->
        {:error, :not_composing}

      edition ->
        manuscript = manuscript(poet)
        {matter, report} = Matter.merge(edition.matter, params, manuscript)
        {:ok, edition} = edition |> Edition.changeset(%{matter: matter}) |> Repo.update()
        {:ok, edition, report}
    end
  end

  @doc false
  def settle(%Edition{} = edition, attrs) do
    {:ok, edition} = edition |> Edition.changeset(attrs) |> Repo.update()
    broadcast_updated(poet_user_id(edition), edition)
    edition
  end

  @doc false
  def broadcast_updated(nil, _edition), do: :ok

  def broadcast_updated(user_id, %Edition{id: id}) do
    Phoenix.PubSub.broadcast(TravelingPoet.PubSub, "user:#{user_id}", {:book_edition_updated, id})
  end

  defp maybe_dispatch(user, edition) do
    if Application.get_env(:traveling_poet, :book_compose_in_background, true),
      do: Composer.dispatch(user, edition),
      else: :ok
  end

  defp reap_if_stale(%Edition{status: "composing"} = edition) do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_minutes, :minute)

    if NaiveDateTime.compare(edition.inserted_at, DateTime.to_naive(cutoff)) == :lt,
      do: Composer.finish(edition.id, {:error, :stale}),
      else: edition
  end

  defp reap_if_stale(other), do: other

  defp poet_user_id(%Edition{poet_id: poet_id}) do
    case Poets.get_poet(poet_id) do
      nil -> nil
      poet -> poet.user_id
    end
  end

  ## PDFs

  @pdf_attempt_kind "book_pdf_attempt"
  # a render past this is settled as failed when next read
  @pdf_stale_after_minutes 25
  @render_token_salt "book render"
  @render_token_max_age 30 * 60

  @doc """
  Whether this user may make PDFs: `:book_pdf_enabled` is "all", "admins"
  (the default until the sprite render has proven itself in production) or
  "off".
  """
  def pdf_enabled?(%{is_admin: admin?}) do
    case Application.get_env(:traveling_poet, :book_pdf_enabled, "admins") do
      "all" -> true
      "admins" -> admin? == true
      _ -> false
    end
  end

  def pdf_enabled?(_user), do: false

  def get_pdf(id), do: Repo.get(Pdf, id)

  @doc "A ready PDF this user owns, or nil."
  def get_owned_pdf(%User{id: user_id}, id) do
    with %Pdf{status: "ready"} = pdf <- Repo.get(Pdf, id),
         %{user_id: ^user_id} <- Poets.get_poet(pdf.poet_id) do
      pdf
    else
      _ -> nil
    end
  end

  @doc "The newest PDF for this poet, settled first if its render went stale."
  def current_pdf(%{id: poet_id}) do
    Pdf
    |> where(poet_id: ^poet_id)
    |> order_by(desc: :id)
    |> limit(1)
    |> Repo.one()
    |> reap_pdf_if_stale()
  end

  @doc "The newest ready PDF for this poet."
  def latest_ready_pdf(%{id: poet_id}) do
    Pdf
    |> where(poet_id: ^poet_id, status: "ready")
    |> order_by(desc: :id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Whether a PDF may be made now, and why not."
  def pdf_blocker(%User{} = user, poet, %Manuscript{} = manuscript) do
    cond do
      not pdf_enabled?(user) -> {:blocked, :pdf_disabled}
      manuscript.chapters == [] -> {:blocked, :empty}
      not user.sprite_provisioned or is_nil(user.sprite_name) -> {:blocked, :no_sprite}
      match?(%Pdf{status: "rendering"}, current_pdf(poet)) -> {:blocked, :already_rendering}
      not Usage.within_budget?(user, @pdf_attempt_kind) -> {:blocked, :daily_cap}
      composing?(poet) -> {:blocked, :poet_busy}
      true -> :ok
    end
  end

  @doc """
  Starts a PDF of the book on the poet's sprite. `opts`: `page_size` (a5, a4,
  letter) and `variant` ("composed" falls back to "plain" when no composed
  edition is ready). Free; the daily attempt cap bounds it.
  """
  def request_pdf(%User{} = user, poet, opts \\ %{}) do
    manuscript = manuscript(poet)

    with :ok <- pdf_blocker(user, poet, manuscript) do
      size = if opts[:page_size] in Pdf.page_sizes(), do: opts[:page_size], else: "a5"
      edition = if opts[:variant] == "composed", do: latest_ready_edition(poet), else: nil

      {:ok, _} = Usage.record(user.id, @pdf_attempt_kind, %{metadata: %{"poet_id" => poet.id}})

      {:ok, pdf} =
        %Pdf{}
        |> Pdf.changeset(%{
          poet_id: poet.id,
          edition_id: edition && edition.id,
          variant: if(edition, do: "composed", else: "plain"),
          page_size: size,
          status: "rendering"
        })
        |> Repo.insert()

      broadcast_pdf_updated(pdf)

      if Application.get_env(:traveling_poet, :book_pdf_in_background, true),
        do: PdfRenderer.dispatch(pdf)

      {:ok, pdf}
    end
  end

  @doc "A signed link token that opens this one PDF's book page for the sprite's browser."
  def render_token(%Pdf{id: id, poet_id: poet_id}) do
    Phoenix.Token.sign(TravelingPoetWeb.Endpoint, @render_token_salt, %{pdf: id, poet: poet_id})
  end

  @doc "The PDF a render token opens, while it is still rendering and the token is fresh."
  def verify_render_token(token) when is_binary(token) do
    with {:ok, %{pdf: id, poet: poet_id}} <-
           Phoenix.Token.verify(TravelingPoetWeb.Endpoint, @render_token_salt, token,
             max_age: @render_token_max_age
           ),
         %Pdf{status: "rendering", poet_id: ^poet_id} = pdf <- Repo.get(Pdf, id) do
      {:ok, pdf}
    else
      _ -> {:error, :invalid}
    end
  end

  def verify_render_token(_), do: {:error, :invalid}

  @doc "What the downloaded file is called."
  def pdf_filename(poet, %Pdf{} = pdf) do
    safe = poet.name |> String.replace(~r/[^\p{L}\p{N} ._-]/u, "") |> String.trim()
    date = pdf.rendered_at && Calendar.strftime(pdf.rendered_at, "%Y-%m-%d")
    Enum.join(Enum.reject([safe, "Traveling Poet", date], &is_nil/1), " - ") <> ".pdf"
  end

  @doc "Every stored PDF object of a poet, for the account purge."
  def pdf_keys(nil), do: []

  def pdf_keys(%{id: poet_id}) do
    Pdf
    |> where([p], p.poet_id == ^poet_id and not is_nil(p.s3_key))
    |> select([p], p.s3_key)
    |> Repo.all()
  end

  @doc false
  def broadcast_pdf_updated(%Pdf{} = pdf) do
    case Poets.get_poet(pdf.poet_id) do
      nil ->
        :ok

      poet ->
        Phoenix.PubSub.broadcast(
          TravelingPoet.PubSub,
          "user:#{poet.user_id}",
          {:book_pdf_updated, pdf.id}
        )
    end
  end

  defp reap_pdf_if_stale(%Pdf{status: "rendering"} = pdf) do
    cutoff = DateTime.add(DateTime.utc_now(), -@pdf_stale_after_minutes, :minute)

    if NaiveDateTime.compare(pdf.inserted_at, DateTime.to_naive(cutoff)) == :lt do
      {:ok, pdf} =
        pdf
        |> Pdf.changeset(%{status: "failed", error: "the render never reported back"})
        |> Repo.update()

      broadcast_pdf_updated(pdf)
      pdf
    else
      pdf
    end
  end

  defp reap_pdf_if_stale(other), do: other

  @doc false
  def user_for(%Edition{} = edition) do
    case poet_user_id(edition) do
      nil -> nil
      user_id -> Accounts.get_user(user_id)
    end
  end
end
