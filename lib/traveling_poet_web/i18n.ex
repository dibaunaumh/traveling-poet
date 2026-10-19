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

  Imported into every template with the rest of the HTML helpers.
  """
  use Phoenix.Component

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

    ~H"""
    <%= for piece <- @pieces do %>
      <%= case piece do %>
        <% {:part, name} -> %>
          {render_slot(Enum.filter(@part, &(&1.name == name)))}
        <% text -> %>
          {text}
      <% end %>
    <% end %>
    """
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
end
