defmodule TravelingPoet.Guide.PlaceTopics do
  @moduledoc """
  The topic tree places are sorted into, for the global village: three
  levels, by subject (Art > Modern & contemporary art > Contemporary art), so
  a textile exhibition and a textile museum sit side by side. Reviewed and
  approved by the founder on 2026-09-24; it lives in
  `priv/data/place_topics.json` and changes only on purpose.

  Not to be confused with `TravelingPoet.Topics`, which are what a companion
  asks their poet to follow on excursion days.

  A place stores up to two topics as PATHS of their third-level slugs
  (`"art/modern-and-contemporary-art/contemporary-art"`), so every level
  above comes for free: a place filed under Contemporary art also answers
  "Art" and "Modern & contemporary art" by prefix.

  Alongside the topics, a place gets a short `place_type` from `types/0`. The
  existing `category` (restaurant, attraction, ...) is too coarse for "the
  textile museums": "attraction" covers museums, temples and parks alike.

  Read at compile time, like everything under `priv/data`: editing the JSON
  needs `mix compile --force`.
  """

  @path "priv/data/place_topics.json"
  @external_resource @path
  @tree @path |> File.read!() |> Jason.decode!() |> Map.fetch!("topics")

  @leaves (for a <- @tree, b <- a["children"], c <- b["children"] do
             {"#{a["slug"]}/#{b["slug"]}/#{c["slug"]}", [a["name"], b["name"], c["name"]]}
           end)
          |> Map.new()

  @types ~w(museum gallery exhibition performance_venue festival_or_event place_of_worship
            historic_site building_or_monument park_or_garden trail_or_viewpoint natural_site
            market shop restaurant cafe bar_or_brewery neighbourhood workshop other)

  @doc "The whole tree as stored: `[%{\"slug\", \"name\", \"children\"}]`."
  def tree, do: @tree

  @doc "Every third-level path, e.g. `art/modern-and-contemporary-art/contemporary-art`."
  def paths, do: @leaves |> Map.keys() |> Enum.sort()

  @doc "Is this a path in the tree (a whole third-level path, nothing else)?"
  def valid?(path), do: Map.has_key?(@leaves, path)

  @doc "The names along a path: `[\"Art\", \"Modern & contemporary art\", \"Contemporary art\"]`, or nil."
  def names(path), do: Map.get(@leaves, path)

  @doc "The short place types a place can have."
  def types, do: @types

  @doc "A type from the list, or \"other\"."
  def normalize_type(type) when is_binary(type) do
    type = type |> String.trim() |> String.downcase()
    if type in @types, do: type, else: "other"
  end

  def normalize_type(_), do: "other"

  @doc """
  For a changeset carrying a first and a second path in `fields`: an unknown
  path is dropped, and a second equal to the first (or without a first) too.
  Shared by places, finds and topics, whose verdicts come from one classifier.
  """
  def drop_unknown_paths(changeset, [first, second]) do
    changeset =
      Enum.reduce([first, second], changeset, fn field, cs ->
        case Ecto.Changeset.get_change(cs, field) do
          nil -> cs
          path -> if valid?(path), do: cs, else: Ecto.Changeset.put_change(cs, field, nil)
        end
      end)

    a = Ecto.Changeset.get_field(changeset, first)

    if a == nil or Ecto.Changeset.get_field(changeset, second) == a,
      do: Ecto.Changeset.put_change(changeset, second, nil),
      else: changeset
  end
end
