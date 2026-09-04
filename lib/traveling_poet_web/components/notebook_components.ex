defmodule TravelingPoetWeb.NotebookComponents do
  @moduledoc """
  The pieces of a journal page that every surface renders the same way — the
  owner's journal, a public journal, and the home page's open spread — so an
  entry looks like the same notebook wherever it is read.
  """

  use TravelingPoetWeb, :html

  alias TravelingPoet.Journal.Media

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

  def raw_markdown(nil), do: ""

  def raw_markdown(text) do
    case MDEx.to_html(text) do
      {:ok, html} -> Phoenix.HTML.raw(html)
      _ -> text
    end
  end

  def section_icon("poem"), do: "✒️"
  def section_icon("description"), do: "🗺️"
  def section_icon("art_culture"), do: "🎭"
  def section_icon("products"), do: "🧺"
  def section_icon("kindness"), do: "💛"
  def section_icon(_), do: ""
end
