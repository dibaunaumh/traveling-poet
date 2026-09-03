defmodule TravelingPoet.Poets.Presets do
  @moduledoc """
  Curated defaults that let someone finish onboarding without typing: poet
  names, personality presets and interest chips. Loaded once at compile time
  from `priv/data/poet_presets.json` (edit the JSON, then `mix compile --force`).
  """

  @path "priv/data/poet_presets.json"
  @external_resource @path
  @presets Jason.decode!(File.read!(@path))

  @names @presets["names"]
  @personalities @presets["personalities"]
  @interests @presets["interests"]

  def names, do: @names
  def personalities, do: @personalities
  def interests, do: @interests

  @doc "A random poet name, avoiding `except` when there is a choice."
  def random_name(except \\ nil) do
    case Enum.reject(@names, &(&1 == except)) do
      [] -> Enum.random(@names)
      rest -> Enum.random(rest)
    end
  end

  def random_personality_index, do: Enum.random(0..(length(@personalities) - 1))

  def personality_at(idx) when is_integer(idx), do: Enum.at(@personalities, idx)
  def personality_at(_), do: nil

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
