defmodule TravelingPoet.Evals.Writing.Checks do
  @moduledoc """
  The writing eval's automatic checks, pure so they are unit-tested.

  `parse/1` turns a model's answer into a page (`title`, `teaser`,
  `sections`) or says why it could not. `metrics/2` measures what a reader
  noticed by eye:

    * **script**: letters outside Latin and Hebrew, and words that mix two
      scripts (`שלוםabc`, Hebrew run into Chinese). A Hebrew page also gets
      its share of Hebrew letters. Japanese or Chinese place names are
      legitimate, so these are signals for the judge page, not verdicts.
    * **disclaimers**: phrases that tell the reader the poet is not really
      there, or name the page a fact came from. Udi found Claude poets
      repeating them; the count says which models do. A heuristic list, in
      both languages.
  """

  @image ~r/!\[[^\]]*\]\([^)]*\)/

  @doc "A model's answer as a page, or `{:error, reason}`."
  def parse(raw) when is_binary(raw) do
    json =
      raw
      |> String.replace(~r/^```(?:json)?\s*|\s*```$/m, "")
      |> then(&Regex.run(~r/\{.*\}/s, &1))

    with [obj] <- json || {:error, "no JSON object in the answer"},
         {:ok, %{"sections" => [_ | _] = sections} = page} <- decode(obj),
         true <- Enum.all?(sections, &section?/1) || {:error, "a section without kind or body"} do
      {:ok,
       %{
         "title" => string(page["title"]),
         "teaser" => string(page["teaser"]),
         "sections" =>
           sections
           |> Enum.reject(&(&1["kind"] == "illustration"))
           |> Enum.map(fn s ->
             %{
               "kind" => s["kind"],
               "title" => string(s["title"]),
               "body" => s["body"] |> String.replace(@image, "") |> String.trim()
             }
           end)
       }}
    else
      {:ok, _} -> {:error, "no sections"}
      {:error, %Jason.DecodeError{}} -> {:error, "invalid JSON"}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse(_), do: {:error, "empty answer"}

  defp decode(obj), do: Jason.decode(obj)

  defp section?(%{"kind" => k, "body" => b}) when is_binary(k) and is_binary(b), do: true
  defp section?(_), do: false

  defp string(s) when is_binary(s), do: s
  defp string(_), do: ""

  # Disclaimer phrases. Kept narrow on purpose: "according to" alone would
  # count every quoted local, so it must point at a page or site.
  @disclaimers %{
    "en" => [
      ~r/\bvirtual(ly)?\b/i,
      ~r/\bnot (actually|really|physically) (there|here)\b/i,
      ~r/\bI (haven't|have not|never|didn't|did not|can't|cannot) (actually |really |physically )?(been|walk|walked|stand|stood|visit|visited|taste|tasted|see|smell)/i,
      ~r/\b(according to|as) (the|its|their|a) (page|website|site|listing|article)\b/i,
      ~r/\bthe (page|website|site|listing|article) (says|notes|mentions|describes|lists|claims)\b/i,
      ~r/\bI read (that|on|in)\b/i,
      ~r/\bfrom (the|a|its|their) (page|website|site|listing)\b/i
    ],
    "he" => [
      ~r/וירטואל/u,
      ~r/לא (באמת|ממש|פיזית) (שם|כאן|הייתי|הלכתי|עמדתי|טעמתי|ראיתי)/u,
      ~r/(מעולם )?לא הייתי (שם|כאן|באמת)/u,
      ~r/לפי (ה)?(אתר|דף|עמוד|כתבה|רישום)/u,
      ~r/כפי ש(ה)?(אתר|דף|עמוד|כתבה)/u,
      ~r/ה(אתר|דף|עמוד|כתבה) (מספר|מספרת|מציין|מציינת|אומר|אומרת|כותב|כותבת|מתאר|מתארת)/u,
      ~r/קראתי (ש|ב|על)/u
    ]
  }

  @foreign ~r/[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Cyrillic}\p{Arabic}\p{Thai}\p{Devanagari}\p{Greek}]/u

  @doc "The page's measurable signals, for the judge page and the report."
  def metrics(%{"sections" => sections} = page, language) do
    text =
      [page["title"], page["teaser"] | Enum.flat_map(sections, &[&1["title"], &1["body"]])]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join("\n")

    words = String.split(text, ~r/\s+/u, trim: true)
    hebrew = count(text, ~r/\p{Hebrew}/u)
    latin = count(text, ~r/\p{Latin}/u)
    patterns = Map.get(@disclaimers, language, @disclaimers["en"])

    disclaimers =
      Enum.flat_map(patterns, fn re ->
        re |> Regex.scan(text) |> Enum.map(&hd/1)
      end)

    %{
      "words" => length(words),
      "foreign_chars" => count(text, @foreign),
      "mixed_words" =>
        text |> String.split(~r/[^\p{L}\p{M}]+/u, trim: true) |> Enum.count(&mixed?/1),
      "hebrew_share" => if(language == "he", do: share(hebrew, hebrew + latin)),
      "disclaimers" => length(disclaimers),
      "disclaimer_examples" => disclaimers |> Enum.uniq() |> Enum.take(5),
      "kinds" => Enum.map(sections, & &1["kind"])
    }
  end

  defp count(text, re), do: re |> Regex.scan(text) |> length()

  defp share(_, 0), do: nil
  defp share(n, d), do: Float.round(n / d, 3)

  # A run of letters from two scripts. Words are split at anything that is
  # not a letter first, so Hebrew's "ה-UNESCO" is two words and fine, while
  # "שלוםabc" is one word and is not.
  defp mixed?(word) do
    scripts =
      [
        {~r/\p{Latin}/u, :latin},
        {~r/\p{Hebrew}/u, :hebrew},
        {@foreign, :other}
      ]
      |> Enum.filter(fn {re, _} -> Regex.match?(re, word) end)

    length(scripts) > 1
  end
end
