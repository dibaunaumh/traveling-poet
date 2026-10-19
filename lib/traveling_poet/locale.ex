defmodule TravelingPoet.Locale do
  @moduledoc """
  The languages the app speaks (card-101).

  One setting per account, `users.locale`, sets both the reader's interface
  and the language their poet writes in (dec-008). A page carries its own
  `journal_entries.language`, stamped by the app when the poet saves it, so
  a page written before a switch keeps its direction and its voice.

  Signed-out visitors get their own language for the interface
  (`TravelingPoetWeb.Plugs.Locale`); page content still follows the page.
  """

  @supported ~w(en he)
  @default "en"
  @rtl ~w(he)

  @names %{"en" => "English", "he" => "Hebrew"}
  @native_names %{"en" => "English", "he" => "עברית"}

  @doc "Every locale the app speaks."
  def supported, do: @supported

  def default, do: @default

  @doc "Whether `locale` is one the app speaks."
  def supported?(locale), do: locale in @supported

  @doc "A supported locale for any input, falling back to the default."
  def normalize(locale) when is_binary(locale) do
    locale = locale |> String.trim() |> String.downcase() |> String.replace("_", "-")

    case locale |> String.split("-") |> hd() do
      # iOS and older Java still say "iw" for Hebrew
      "iw" -> "he"
      base when base in @supported -> base
      _ -> nil
    end
  end

  def normalize(_), do: nil

  @doc "`\"rtl\"` or `\"ltr\"`."
  def dir(locale) when locale in @rtl, do: "rtl"
  def dir(_), do: "ltr"

  def rtl?(locale), do: locale in @rtl

  @doc "The language's English name, for the poet (`\"Hebrew\"`)."
  def name(locale), do: Map.get(@names, locale, @names[@default])

  @doc "The language's own name, for a picker (`\"עברית\"`)."
  def native_name(locale), do: Map.get(@native_names, locale, @native_names[@default])

  @doc """
  The best supported locale for an `Accept-Language` header, by q-value,
  or nil when it names none of them.
  """
  def from_accept_language(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, index} ->
      case String.split(part, ";") do
        [tag | params] ->
          case normalize(tag) do
            nil -> []
            locale -> [{locale, quality(params), index}]
          end

        _ ->
          []
      end
    end)
    |> Enum.reject(fn {_, q, _} -> q <= 0 end)
    |> Enum.sort_by(fn {_, q, index} -> {-q, index} end)
    |> case do
      [{locale, _, _} | _] -> locale
      [] -> nil
    end
  end

  def from_accept_language(_), do: nil

  defp quality(params) do
    Enum.find_value(params, 1.0, fn param ->
      with ["q", value] <- param |> String.trim() |> String.split("=", parts: 2),
           {q, _} <- Float.parse(String.trim(value)) do
        q
      else
        _ -> nil
      end
    end)
  end
end
