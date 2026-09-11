defmodule TravelingPoetWeb.NotebookComponents do
  @moduledoc """
  The pieces of a journal page that every surface renders the same way — the
  owner's journal, a public journal, and the home page's open spread — so an
  entry looks like the same notebook wherever it is read.
  """

  use TravelingPoetWeb, :html

  alias TravelingPoet.Journal.Media

  attr :entry, :map, required: true
  attr :day, :integer, default: nil, doc: "journey day, see Journal.journey_day/2"
  attr :tag, :string, default: "h2"
  attr :show_date, :boolean, default: true

  @doc """
  The entry's heading, the same on every surface: the journey day in the
  margin hand, the poet's title (falling back to the place, then "Journal"),
  and the date. The day comes from the app, never from the stored title.
  """
  def entry_heading(assigns) do
    ~H"""
    <.dynamic_tag tag_name={@tag} class="notebook-title">
      <span :if={@day} class="notebook-day">Day {@day}</span>
      {entry_title(@entry)}
      <span :if={@show_date} class="notebook-date ml-2">
        {Calendar.strftime(@entry.entry_date, "%B %-d, %Y")}
      </span>
    </.dynamic_tag>
    """
  end

  def entry_title(entry), do: entry.title || entry.place_name || "Journal"

  attr :section, :any, required: true
  attr :media, :any, default: nil
  attr :clamp, :boolean, default: false, doc: "cap the prose at a few lines (home page spread)"

  @doc "One journal section: a taped-on illustration, or a titled block of the poet's prose."
  def section(%{section: %{kind: "illustration"}} = assigns) do
    ~H"""
    <figure :if={@media} class="taped-photo my-4">
      <img
        src={~p"/media/#{@media.id}"}
        alt={@media.alt_text || "illustration"}
        class="rounded-xl max-w-full shadow"
        loading="lazy"
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

  def section(assigns) do
    ~H"""
    <div class={@section.kind == "poem" && "notebook-poem"}>
      <h3 :if={@section.title} class="notebook-section-title mb-1">
        {section_icon(@section.kind)} {@section.title}
      </h3>
      <div class={["prose prose-sm max-w-none", @clamp && "spread-clamp"]}>
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

  @doc """
  The poet's markdown as sanitized HTML.

  Section bodies come from the sprite, which is user-driven territory, so
  they are cleaned the same way chat is. Images are the one place the rule
  goes further than the sanitizer: a drawing may only be embedded from this
  app's own `/media/:id` route, and only when the caller vouches for the id
  (`allowed_media_ids`, the poet's own media for this entry). Anything else,
  which would be a photo found online, collapses to its alt text. That keeps
  the "never embed photos you find online" rule in `priv/data/AGENTS.md`
  enforced here rather than only in the prompt.
  """
  def raw_markdown(text, allowed_media_ids \\ [])

  def raw_markdown(nil, _allowed), do: ""

  def raw_markdown(text, allowed_media_ids) do
    allowed = MapSet.new(allowed_media_ids, &to_string/1)

    with {:ok, doc} <- MDEx.parse_document(text),
         doc = MDEx.traverse_and_update(doc, &own_images_only(&1, allowed)),
         {:ok, html} <- MDEx.to_html(doc, sanitize: MDEx.Document.default_sanitize_options()) do
      Phoenix.HTML.raw(html)
    else
      _ -> text
    end
  end

  defp own_images_only(%MDEx.Image{url: "/media/" <> id} = image, allowed) do
    if MapSet.member?(allowed, id), do: image, else: alt_text(image)
  end

  defp own_images_only(%MDEx.Image{} = image, _allowed), do: alt_text(image)
  defp own_images_only(node, _allowed), do: node

  defp alt_text(%MDEx.Image{nodes: nodes}) do
    %MDEx.Text{literal: Enum.map_join(nodes, "", &node_text/1)}
  end

  defp node_text(%MDEx.Text{literal: literal}), do: literal
  defp node_text(%{nodes: nodes}), do: Enum.map_join(nodes, "", &node_text/1)
  defp node_text(_), do: ""

  def section_icon("poem"), do: "✒️"
  def section_icon("description"), do: "🗺️"
  def section_icon("art_culture"), do: "🎭"
  def section_icon("products"), do: "🧺"
  def section_icon("kindness"), do: "💛"
  def section_icon(_), do: ""
end
