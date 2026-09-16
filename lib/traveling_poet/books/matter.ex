defmodule TravelingPoet.Books.Matter do
  @moduledoc """
  The words the poet writes around its journal for a composed edition, and
  the rules they are held to on the way in.

  Stored on `Books.Edition.matter` with string keys:

    * `"dedication"`: a line or two, for the companion
    * `"foreword"`: before the journey
    * `"epilogue"`: after it
    * `"chapter_openers"`: `%{chapter_key => text}`, one per stay
    * `"pull_quotes"`: `[%{"entry_date", "text"}]`, verified by `Books.Quotes`

  `merge/3` is pure. A put may carry any subset: fields it names replace
  what was there, openers merge per chapter, and the quote list is replaced
  whole (the poet sends every quote it wants). A field that breaks a rule is
  rejected on its own and reported; the rest of the put still lands, so one
  long foreword never costs the dedication.
  """

  alias TravelingPoet.Books.{Manuscript, Quotes}

  @limits %{"dedication" => 300, "foreword" => 2500, "epilogue" => 2500, "chapter_opener" => 900}

  def limits, do: Map.put(@limits, "pull_quotes", Quotes.max_quotes())

  @doc """
  Applies a put to the stored matter. Returns `{matter, report}`, where the
  report carries `written`, `rejected` (field => reason), `accepted_quotes`,
  `dropped_quotes`, `unknown_chapters` and `missing_openers`.
  """
  def merge(stored, params, manuscript) when is_map(params) do
    stored = stored || %{}
    report = %{written: [], rejected: %{}, unknown_chapters: []}

    {matter, report} =
      Enum.reduce(~w(dedication foreword epilogue), {stored, report}, fn field, acc ->
        put_text(acc, field, Map.get(params, field))
      end)

    {matter, report} =
      put_openers({matter, report}, Map.get(params, "chapter_openers"), manuscript)

    {matter, report} = put_quotes({matter, report}, Map.get(params, "pull_quotes"), manuscript)

    report =
      report
      |> Map.put(:written, Enum.reverse(report.written))
      |> Map.put(:missing_openers, missing_openers(matter, manuscript))
      |> Map.put_new(:accepted_quotes, Map.get(matter, "pull_quotes", []))
      |> Map.put_new(:dropped_quotes, [])

    {matter, report}
  end

  @doc "Whether the edition carries enough of the poet's words to call it composed."
  def landed?(matter) when is_map(matter),
    do: present?(matter["dedication"]) or present?(matter["foreword"])

  def landed?(_), do: false

  @doc """
  The matter as the book renders it: openers keyed by chapter, quotes grouped
  by day and re-checked against today's entries. Blank fields are nil.
  """
  def for_render(nil, _manuscript), do: nil

  def for_render(matter, manuscript) when is_map(matter) do
    quotes = Quotes.still_present(Map.get(matter, "pull_quotes", []), manuscript)

    %{
      dedication: blank_to_nil(matter["dedication"]),
      foreword: blank_to_nil(matter["foreword"]),
      epilogue: blank_to_nil(matter["epilogue"]),
      openers:
        (matter["chapter_openers"] || %{})
        |> Enum.flat_map(fn {k, v} -> if present?(v), do: [{k, v}], else: [] end)
        |> Map.new(),
      quotes_by_date: Enum.group_by(quotes, &Date.from_iso8601!(&1["entry_date"]), & &1["text"])
    }
  end

  defp put_text({matter, report}, _field, nil), do: {matter, report}

  defp put_text({matter, report}, field, value) when is_binary(value) do
    text = String.trim(value)
    max = Map.fetch!(@limits, field)

    cond do
      String.length(text) > max ->
        {matter, reject(report, field, "longer than #{max} characters")}

      true ->
        {Map.put(matter, field, text), %{report | written: [field | report.written]}}
    end
  end

  defp put_text({matter, report}, field, _other),
    do: {matter, reject(report, field, "must be text")}

  defp put_openers(acc, nil, _manuscript), do: acc

  # Accepts a map of chapter key => text, or a list of %{chapter, text}.
  defp put_openers({matter, report}, openers, manuscript) when is_list(openers) do
    as_map =
      openers
      |> Enum.flat_map(fn
        %{"chapter" => k, "text" => t} -> [{to_string(k), t}]
        _ -> []
      end)
      |> Map.new()

    put_openers({matter, report}, as_map, manuscript)
  end

  defp put_openers({matter, report}, openers, manuscript) when is_map(openers) do
    keys = manuscript.chapters |> Enum.map(&Manuscript.chapter_key/1) |> MapSet.new()
    max = @limits["chapter_opener"]
    existing = Map.get(matter, "chapter_openers", %{})

    {merged, report} =
      Enum.reduce(openers, {existing, report}, fn {key, text}, {acc, rep} ->
        key = to_string(key)

        cond do
          not MapSet.member?(keys, key) ->
            {acc, %{rep | unknown_chapters: [key | rep.unknown_chapters]}}

          not is_binary(text) ->
            {acc, reject(rep, "chapter_openers.#{key}", "must be text")}

          String.length(String.trim(text)) > max ->
            {acc, reject(rep, "chapter_openers.#{key}", "longer than #{max} characters")}

          true ->
            {Map.put(acc, key, String.trim(text)), rep}
        end
      end)

    written =
      if merged != existing, do: ["chapter_openers" | report.written], else: report.written

    {Map.put(matter, "chapter_openers", merged),
     %{report | written: written, unknown_chapters: Enum.reverse(report.unknown_chapters)}}
  end

  defp put_openers({matter, report}, _other, _manuscript),
    do: {matter, reject(report, "chapter_openers", "must be a map of chapter to text")}

  defp put_quotes(acc, nil, _manuscript), do: acc

  defp put_quotes({matter, report}, quotes, manuscript) when is_list(quotes) do
    {accepted, dropped} = Quotes.validate(quotes, manuscript)

    {Map.put(matter, "pull_quotes", accepted),
     report
     |> Map.put(:written, ["pull_quotes" | report.written])
     |> Map.put(:accepted_quotes, accepted)
     |> Map.put(:dropped_quotes, dropped)}
  end

  defp put_quotes({matter, report}, _other, _manuscript),
    do: {matter, reject(report, "pull_quotes", "must be a list of {entry_date, text}")}

  defp missing_openers(matter, manuscript) do
    written = Map.get(matter, "chapter_openers", %{})

    manuscript.chapters
    |> Enum.map(&Manuscript.chapter_key/1)
    |> Enum.reject(&present?(Map.get(written, &1)))
  end

  defp reject(report, field, reason),
    do: %{report | rejected: Map.put(report.rejected, field, reason)}

  defp present?(s) when is_binary(s), do: String.trim(s) != ""
  defp present?(_), do: false

  defp blank_to_nil(s), do: if(present?(s), do: s, else: nil)
end
