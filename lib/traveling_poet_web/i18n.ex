defmodule TravelingPoetWeb.I18n do
  @moduledoc """
  Translated sentences with markup inside them (card-101).

  A sentence is translated whole, never glued together from pieces: word
  order differs between languages, and Hebrew puts the link at the other end
  of the line. The markup goes in as a placeholder, `marker/1`, and `rich/1`
  puts it back after the translated text has been escaped:

      <.rich text={dgettext("journal", "Read %{guide} before you go.", guide: marker(:guide))}>
        <:part name="guide">
          <.link navigate={~p"/guide"}>{dgettext("journal", "the guide")}</.link>
        </:part>
      </.rich>

  A part is rendered to a string and trimmed, so it may hold links, icons and
  function components, not a stateful LiveComponent.

  Imported into every template with the rest of the HTML helpers.
  """
  use Phoenix.Component
  use Gettext, backend: TravelingPoetWeb.Gettext

  # Private-use characters: never in a translation, never in user text that
  # reaches a msgid
  @open "\u{E000}"
  @close "\u{E001}"
  @split ~r/\x{E000}([a-z_]+)\x{E001}/u

  @doc "A placeholder for the part of a sentence called `name`."
  def marker(name) when is_atom(name) or is_binary(name), do: @open <> to_string(name) <> @close

  attr :text, :string, required: true, doc: "the translated sentence, with marker/1 placeholders"

  slot :part, doc: "one per placeholder" do
    attr :name, :string, required: true
  end

  @doc "A translated sentence with each placeholder replaced by its part."
  def rich(assigns) do
    assigns = assign(assigns, :pieces, pieces(assigns.text))

    # phx-no-format: any whitespace the formatter put between the pieces
    # would show as a space between a word and its link
    ~H"""
    <span phx-no-format><%= for piece <- @pieces do %><%= case piece do %><% {:part, name} -> %>{trimmed(render_slot(Enum.filter(@part, &(&1.name == name))))}<% text -> %>{text}<% end %><% end %></span>
    """
  end

  # A part, trimmed: a slot the formatter broke over several lines would
  # otherwise bring a space in with it
  defp trimmed(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> String.trim()
    |> Phoenix.HTML.raw()
  end

  @doc false
  def pieces(text) do
    @split
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn piece ->
      case Regex.run(@split, piece) do
        [^piece, name] -> {:part, name}
        _ -> piece
      end
    end)
  end

  @doc """
  The words the page's own scripts write (`assets/js/strings.js`), in the
  process's language, as JSON safe inside a `<script>`. A `{name}` stays for
  the script to fill.
  """
  def js_strings_json do
    Jason.encode!(js_strings(), escape: :html_safe)
  end

  defp js_strings do
    %{
      marker_sent: dgettext("js", "sent to your poet"),
      marker_waiting: dgettext("js", "waiting to be sent"),
      marker_no_note: dgettext("js", "no note yet"),
      marker_edit: dgettext("js", "Edit"),
      marker_write: dgettext("js", "Write it"),
      marker_remove: dgettext("js", "Remove"),
      marker_tell: dgettext("js", "Tell your poet"),
      marker_note_placeholder: dgettext("js", "What would you change, or want more of?"),
      marker_save: dgettext("js", "Save"),
      marker_cancel: dgettext("js", "Cancel"),
      marker_mark_title: dgettext("js", "%{label} (tap for options)", label: "{label}"),
      marker_pin_title: dgettext("js", "%{label}. Tap for options.", label: "{label}"),
      marker_pin_orphan_title:
        dgettext("js", "%{label} (this passage has since changed). Tap for options.",
          label: "{label}"
        ),
      narration_reading: dgettext("js", "Reading this page, this can take a minute"),
      narration_progress:
        dgettext("js", "%{elapsed} of %{total}", elapsed: "{elapsed}", total: "{total}"),
      narration_failed: dgettext("js", "The recording would not play. Try again in a moment."),
      play: dgettext("js", "Play"),
      pause: dgettext("js", "Pause"),
      book_pages: dgettext("js", "%{count} pages", count: "{count}"),
      book_no_pages: dgettext("js", "Page numbers unavailable"),
      copied: dgettext("js", "Copied"),
      copy_failed: dgettext("js", "Could not copy"),
      copy_link: dgettext("js", "Copy link"),
      village_subjects: dgettext("js", "Subjects"),
      village_all_subjects: dgettext("js", "All subjects"),
      village_layout: dgettext("js", "How to lay it out"),
      village_tiles: dgettext("js", "Tiles"),
      village_shelf: dgettext("js", "Shelf"),
      village_empty: dgettext("js", "Nothing here yet."),
      village_found_by: dgettext("js", "found by %{count} poets", count: "{count}"),
      find: dgettext("js", "Find"),
      find_kinds: find_kinds(),
      short_months: short_months(),
      short_date: dgettext("js", "%{month} %{day}", month: "{month}", day: "{day}"),
      map_show_everything: dgettext("js", "Show everything"),
      map_view_details: dgettext("js", "View details ↗"),
      map_your_poet: dgettext("js", "Your poet"),
      iap_unavailable: dgettext("js", "Credit packs are not available right now.")
    }
  end

  # What a find is, as the guide says it; "other" is simply a find
  defp find_kinds do
    TravelingPoet.Topics.Find.kinds()
    |> Map.new(&{&1, TravelingPoetWeb.GuideComponents.humanize_category(&1)})
    |> Map.put("other", dgettext("js", "Find"))
  end

  defp short_months do
    for month <- 1..12 do
      TravelingPoet.Locale.format_date(Date.new!(2026, month, 1), :month_abbr)
    end
  end
end
