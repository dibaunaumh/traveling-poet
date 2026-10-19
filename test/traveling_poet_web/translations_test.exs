defmodule TravelingPoetWeb.TranslationsTest do
  @moduledoc """
  Every string the app shows has its Hebrew (card-101): a message added to
  the code without one would reach a Hebrew reader in English. Run
  `mix gettext.extract --merge` and fill `priv/gettext/he/`.
  """
  use ExUnit.Case, async: true

  alias Expo.Message

  @gettext Path.expand("../../priv/gettext", __DIR__)

  for pot <- Path.wildcard(Path.join(@gettext, "*.pot")) do
    domain = Path.basename(pot, ".pot")

    test "every #{domain} message has its Hebrew" do
      pot = Expo.PO.parse_file!(unquote(pot))
      po_path = Path.join(@gettext, "he/LC_MESSAGES/#{unquote(domain)}.po")

      assert File.exists?(po_path), "missing #{po_path}: run mix gettext.extract --merge"

      translated =
        po_path
        |> Expo.PO.parse_file!()
        |> Map.fetch!(:messages)
        |> Enum.reject(&Message.has_flag?(&1, "fuzzy"))
        |> Enum.filter(&translated?/1)
        |> MapSet.new(&Message.key/1)

      missing =
        pot.messages
        |> Enum.map(&Message.key/1)
        |> Enum.reject(&MapSet.member?(translated, &1))
        |> Enum.map(fn {_ctxt, msgid} -> msgid end)

      assert missing == [], "untranslated in he/#{unquote(domain)}.po: #{inspect(missing)}"
    end
  end

  defp translated?(%Message.Singular{msgstr: msgstr}), do: IO.iodata_to_binary(msgstr) != ""

  defp translated?(%Message.Plural{msgstr: msgstr}),
    do: map_size(msgstr) > 0 and Enum.all?(msgstr, fn {_, s} -> IO.iodata_to_binary(s) != "" end)
end
