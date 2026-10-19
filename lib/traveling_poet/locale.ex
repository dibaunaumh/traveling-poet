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

  @doc """
  The language the current process speaks: the Gettext locale that
  `Plugs.Locale`, `UserAuth` or a background sender's `with_locale/2` set.
  """
  def current, do: normalize(Gettext.get_locale(TravelingPoetWeb.Gettext)) || @default

  @doc """
  Runs `fun` in `locale`'s language, for whatever is written outside a
  request: an email, a push, a Telegram note.
  """
  def with_locale(locale, fun) do
    Gettext.with_locale(TravelingPoetWeb.Gettext, normalize(locale) || @default, fun)
  end

  ## Dates

  # Each named format in each language. English is exactly what the app
  # printed before there was a second language. Hebrew puts the day first
  # with the prefix ב- on the month ("18 באוקטובר 2026").
  @formats %{
    "en" => %{
      long: "%B %-d, %Y",
      weekday_long: "%A, %B %-d, %Y",
      month_day: "%B %-d",
      short: "%b %-d",
      short_year: "%b %-d, %Y",
      day_month: "%-d %B",
      day_mon: "%-d %b",
      month_year: "%B %Y",
      month: "%B",
      time: "%H:%M"
    },
    "he" => %{
      long: "%-d ב%B %Y",
      weekday_long: "יום %A, %-d ב%B %Y",
      month_day: "%-d ב%B",
      short: "%-d ב%b",
      short_year: "%-d ב%b %Y",
      day_month: "%-d ב%B",
      day_mon: "%-d ב%b",
      month_year: "%B %Y",
      month: "%B",
      time: "%H:%M"
    }
  }

  @month_names %{
    "he" =>
      ~w(ינואר פברואר מרץ אפריל מאי יוני יולי אוגוסט ספטמבר אוקטובר נובמבר דצמבר)
      |> List.to_tuple()
  }

  @abbreviated_month_names %{
    "he" => ~w(ינו׳ פבר׳ מרץ אפר׳ מאי יוני יולי אוג׳ ספט׳ אוק׳ נוב׳ דצמ׳) |> List.to_tuple()
  }

  # Monday first, as Calendar.strftime counts them
  @day_names %{
    "he" => ~w(שני שלישי רביעי חמישי שישי שבת ראשון) |> List.to_tuple()
  }

  @doc """
  A date (or datetime) in one of the app's named formats, in `locale` (the
  current process's by default): `:long` "October 18, 2026" /
  "18 באוקטובר 2026", `:short` "Oct 18" / "18 באוק׳", and `:weekday_long`,
  `:month_day`, `:short_year`, `:day_month`, `:day_mon`, `:month_year`,
  `:month`, `:time`.
  """
  def format_date(date, format, locale \\ nil) do
    locale = normalize(locale) || current()
    pattern = @formats |> Map.get(locale, @formats[@default]) |> Map.fetch!(format)

    Calendar.strftime(date, pattern, names(locale))
  end

  defp names(locale) do
    case @month_names[locale] do
      nil ->
        []

      months ->
        abbreviated = @abbreviated_month_names[locale]
        days = @day_names[locale]

        [
          month_names: &elem(months, &1 - 1),
          abbreviated_month_names: &elem(abbreviated, &1 - 1),
          day_of_week_names: &elem(days, &1 - 1),
          abbreviated_day_of_week_names: &elem(days, &1 - 1)
        ]
    end
  end
end
