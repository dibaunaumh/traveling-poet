defmodule TravelingPoet.Poets.Presets do
  @moduledoc """
  Curated defaults that let someone finish onboarding without typing: poet
  names, personality presets and interest chips. Loaded once at compile time
  from `priv/data/poet_presets.json` (edit the JSON, then `mix compile --force`).

  Each language has its own set (card-101): the top-level lists are English,
  and `"he"` holds the Hebrew names, personalities and chips. A Hebrew reader
  meets a poet with a Hebrew name and a personality written in Hebrew, which
  is what the poet then reads about itself. A language without its own set
  gets the English one.
  """

  @path "priv/data/poet_presets.json"
  @external_resource @path
  @presets Jason.decode!(File.read!(@path))

  @sets %{
    "en" => Map.take(@presets, ["names", "personalities", "interests"]),
    "he" => @presets["he"]
  }

  defp set(locale), do: Map.get(@sets, locale, @sets["en"])

  def names(locale \\ "en"), do: set(locale)["names"]
  def personalities(locale \\ "en"), do: set(locale)["personalities"]
  def interests(locale \\ "en"), do: set(locale)["interests"]

  @doc """
  A random poet name for onboarding, avoiding `except` (the name just shown)
  and every name in `taken` (`Poets.taken_names/0`), so two readers do not
  both end up with a Ferris Lune. Once every preset is taken, a new name is
  made from a preset first name and another preset's last name; only when
  those are gone too does a taken name come back.
  """
  def random_name(except \\ nil, taken \\ MapSet.new(), locale \\ "en") do
    names = names(locale)

    free = fn names ->
      Enum.reject(names, &(&1 == except or MapSet.member?(taken, normalize(&1))))
    end

    case free.(names) do
      [] ->
        case free.(combined_names(names)) do
          [] -> Enum.random(names)
          made -> Enum.random(made)
        end

      rest ->
        Enum.random(rest)
    end
  end

  @doc "A name as `taken` holds it: trimmed, lower case."
  def normalize(name) when is_binary(name), do: name |> String.trim() |> String.downcase()
  def normalize(_), do: ""

  # "Ferris" + "Quill" from "Ferris Lune" and "Tobias Quill".
  defp combined_names(names) do
    two_part = names |> Enum.map(&String.split/1) |> Enum.filter(&(length(&1) == 2))

    for [first, _] <- two_part, [_, last] <- two_part, "#{first} #{last}" not in names do
      "#{first} #{last}"
    end
  end

  def random_personality_index(locale \\ "en"),
    do: Enum.random(0..(length(personalities(locale)) - 1))

  def personality_at(idx, locale \\ "en")
  def personality_at(idx, locale) when is_integer(idx), do: Enum.at(personalities(locale), idx)
  def personality_at(_, _), do: nil

  @doc """
  Splits a comma- or newline-separated interests string into a trimmed list.
  Shared by onboarding and Settings so both produce the same shape.
  """
  def split_interests(nil), do: []

  def split_interests(text) when is_binary(text) do
    text
    |> String.split(~r/[,\n]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end
