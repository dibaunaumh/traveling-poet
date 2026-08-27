defmodule TravelingPoetWeb.PublicJournalLive do
  use TravelingPoetWeb, :live_view

  alias TravelingPoet.{Journal, Poets}
  alias TravelingPoet.Journal.Media

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    case Poets.get_public_poet_by_slug(slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "That journal doesn't exist or isn't public.")
         |> push_navigate(to: ~p"/")}

      poet ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(TravelingPoet.PubSub, "poet:#{poet.id}")
        end

        {:ok,
         socket
         |> assign(:poet, poet)
         |> assign(:page_title, "#{poet.name} — Traveling Poet")
         |> assign_journal(poet, nil)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns[:poet] do
      nil ->
        {:noreply, socket}

      poet ->
        date =
          with %{"date" => date_str} <- params,
               {:ok, date} <- Date.from_iso8601(date_str) do
            date
          else
            _ -> nil
          end

        {:noreply, assign_journal(socket, poet, date)}
    end
  end

  @impl true
  def handle_event("react", %{"kind" => kind}, socket) do
    user = socket.assigns[:current_user]
    entry = socket.assigns.entry

    if user && entry do
      Journal.toggle_reaction(entry.id, user.id, kind, "public")
      {:noreply, assign(socket, :public_reactions, public_reaction_counts(entry.id))}
    else
      {:noreply, put_flash(socket, :error, "Sign in to react.")}
    end
  end

  @impl true
  def handle_info({:journal_published, _entry_id}, socket) do
    poet = Poets.get_poet(socket.assigns.poet.id)
    {:noreply, socket |> assign(:poet, poet) |> assign_journal(poet, nil)}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_journal(socket, poet, date) do
    entries = Journal.list_entries(poet.id, status: "published")

    entry =
      cond do
        date -> published_entry(poet, date)
        entries != [] -> Journal.preload_entry(hd(entries))
        true -> nil
      end

    socket
    |> assign(:entries, entries)
    |> assign(:entry, entry)
    |> assign(:entry_media, entry_media_map(entry))
    |> assign(:extra_media, extra_media(entry))
    |> assign(:public_reactions, entry && public_reaction_counts(entry.id))
    |> assign(:path_points, Poets.list_path_points(poet.id))
  end

  defp extra_media(nil), do: []
  defp extra_media(entry), do: Journal.unattached_illustrations(entry, entry.sections)

  defp published_entry(poet, date) do
    case Journal.get_entry_preloaded(poet.id, date) do
      %{status: "published"} = entry -> entry
      _ -> nil
    end
  end

  defp entry_media_map(nil), do: %{}

  defp entry_media_map(entry) do
    entry.sections
    |> Enum.map(& &1.media_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Journal.get_media/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new(&{&1.id, &1})
  end

  defp public_reaction_counts(entry_id) do
    Journal.list_reactions(entry_id, "public")
    |> Enum.frequencies_by(& &1.kind)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={assigns[:current_user]}>
      <div class="mx-auto max-w-3xl">
        <div class="flex items-center gap-3 mb-3">
          <img
            :if={@poet.avatar_url}
            src={@poet.avatar_url}
            class="w-12 h-12 rounded-full object-cover"
            alt={@poet.name}
          />
          <div>
            <h1 class="text-xl font-semibold">{@poet.name}</h1>
            <p class="text-sm opacity-70">
              a traveling poet
              <span :if={@poet.current_place_name}>· 📍 {@poet.current_place_name}</span>
            </p>
          </div>
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm ml-auto">World map</.link>
        </div>

        <div
          id="public-poet-map"
          phx-hook="PoetMap"
          phx-update="ignore"
          class="w-full h-56 rounded-xl border border-base-300 z-0"
          data-points={Jason.encode!(map_points(@path_points, @poet))}
        >
        </div>

        <article :if={@entry} class="notebook-page mt-6">
          <div class="flex items-center justify-between mb-2">
            <h2 class="notebook-title">
              {@entry.title || @entry.place_name || "Journal"}
              <span class="notebook-date ml-2">
                {Calendar.strftime(@entry.entry_date, "%B %-d, %Y")}
              </span>
            </h2>
            <div class="flex gap-1">
              <.link
                :for={{label, date} <- entry_nav(@entries, @entry)}
                navigate={~p"/p/#{@poet.slug}/#{date}"}
                class="btn btn-ghost btn-xs"
              >
                {label}
              </.link>
            </div>
          </div>

          <div :for={section <- @entry.sections} class="mb-6">
            <.section section={section} media={@entry_media[section.media_id]} />
          </div>

          <div :for={media <- @extra_media} class="mb-6">
            <.section section={%{kind: "illustration"}} media={media} />
          </div>

          <div class="flex items-center gap-2 border-t border-base-300 pt-3 mt-4">
            <button
              :for={{kind, emoji} <- reaction_kinds()}
              phx-click="react"
              phx-value-kind={kind}
              class="btn btn-ghost btn-sm"
            >
              {emoji}
              <span :if={@public_reactions[kind]} class="text-xs">{@public_reactions[kind]}</span>
            </button>
          </div>
        </article>

        <div :if={is_nil(@entry)} class="mt-10 text-center opacity-70">
          <p>No published entries yet — check back soon.</p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :section, :any, required: true
  attr :media, :any, default: nil

  defp section(%{section: %{kind: "illustration"}} = assigns) do
    ~H"""
    <figure :if={@media} class="taped-photo my-4">
      <img
        src={~p"/media/#{@media.id}"}
        alt={@media.alt_text || "illustration"}
        class="rounded-xl max-w-full shadow"
      />
      <figcaption class="text-xs opacity-60 mt-1 flex flex-wrap gap-x-3">
        <span :if={@media.alt_text}>{@media.alt_text}</span>
        <a
          :for={src <- Media.source_items(@media)}
          href={src["url"]}
          target="_blank"
          rel="noopener noreferrer nofollow"
          class="link"
        >
          {src["label"] || "see the real place"} ↗
        </a>
      </figcaption>
    </figure>
    """
  end

  defp section(assigns) do
    ~H"""
    <div class={@section.kind == "poem" && "notebook-poem"}>
      <h3 :if={@section.title} class="notebook-section-title mb-1">{@section.title}</h3>
      <div class="prose prose-sm max-w-none">
        {raw_markdown(@section.body)}
      </div>
      <a
        :if={@section.metadata["source_url"]}
        href={@section.metadata["source_url"]}
        target="_blank"
        rel="noopener noreferrer nofollow"
        class="link text-sm"
      >
        {@section.metadata["source_label"] || @section.metadata["source_url"]} ↗
      </a>
    </div>
    """
  end

  defp raw_markdown(nil), do: ""

  defp raw_markdown(text) do
    case MDEx.to_html(text) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      _ -> text
    end
  end

  defp reaction_kinds do
    [{"love", "❤️"}, {"inspiring", "✨"}, {"want_more", "➕"}]
  end

  defp map_points(path_points, poet) do
    points = Enum.map(path_points, fn p -> %{lat: p.lat, lng: p.lng, name: p.place_name} end)

    current =
      if poet.current_lat do
        %{lat: poet.current_lat, lng: poet.current_lng, name: poet.current_place_name}
      end

    planned =
      if TravelingPoet.Poets.Poet.mode(poet) == "scout" do
        Poets.list_stops(poet.id)
        |> Enum.filter(&is_nil(&1.visited_at))
        |> Enum.map(fn s -> %{lat: s.lat, lng: s.lng, name: s.place_name} end)
      else
        []
      end

    %{path: points, current: current, planned: planned, poet: poet.name}
  end

  defp entry_nav(entries, current) do
    dates = Enum.map(entries, & &1.entry_date) |> Enum.sort(Date)
    idx = Enum.find_index(dates, &(&1 == current.entry_date))

    # ISO strings, not Date structs — Date has no Phoenix.Param impl, and a
    # bare struct in ~p"/journal/#{date}" crashes the render (only once a poet
    # has 2+ entries, which is why day one didn't catch it)
    prev =
      if idx && idx > 0, do: [{"← earlier", Date.to_iso8601(Enum.at(dates, idx - 1))}], else: []

    next =
      if idx && idx < length(dates) - 1,
        do: [{"later →", Date.to_iso8601(Enum.at(dates, idx + 1))}],
        else: []

    prev ++ next
  end
end
