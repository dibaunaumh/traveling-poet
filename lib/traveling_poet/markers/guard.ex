defmodule TravelingPoet.Markers.Guard do
  @moduledoc """
  Keeps a revision surgical.

  When a published entry is re-put while it carries feedback markers, only the
  passages a marker asked to change may change. Every other section comes
  back exactly as it was stored: same title, body, media and metadata. Praise
  markers (Interesting, Beautiful) ask for nothing, so an entry marked only
  with praise is returned untouched.

  The app owns this rule rather than trusting the skill text alone, because
  `Journal.replace_sections/2` is wholesale: one over-eager rewrite loses the
  passages the reader liked. The poet learns what was kept from the endpoint's
  reply, so its chat message does not claim changes that never landed.

  Pure functions: the controller decides when to apply them.
  """

  alias TravelingPoet.Journal.{Marker, Section}

  @praise ~w(interesting beautiful)
  # A revision turn runs within minutes of the digest; older markers belong to
  # earlier revisions and must not fence a change the reader asked for in chat.
  @recent_minutes 30

  @doc "Markers that define the revision in progress: pending, or sent within the last #{@recent_minutes} min."
  def active_markers(markers, now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -@recent_minutes, :minute)

    Enum.filter(markers, fn %Marker{sent_at: sent_at} ->
      is_nil(sent_at) or DateTime.compare(sent_at, cutoff) != :lt
    end)
  end

  @doc """
  Restores every section no active marker asked to change.

  `existing` are the stored `%Section{}`s in position order; `incoming` the
  attrs the poet sent (string or atom keys). Sections are paired by kind, in
  order, so an added illustration does not shift the pairing. A protected
  section the poet dropped is put back at its old position.

  Returns `{sections_attrs, kept}` where `kept` lists the kinds of protected
  sections whose incoming version differed (or was missing) and was therefore
  overridden.
  """
  def protect(existing, incoming, markers) do
    changeable =
      existing
      |> Enum.filter(fn section ->
        Enum.any?(markers, &(asks_change?(&1) and targets?(&1, section)))
      end)
      |> MapSet.new(& &1.id)

    incoming = Enum.map(incoming, &normalize/1)
    {paired, unpaired_existing} = pair_by_kind(existing, incoming)

    {merged, kept} =
      Enum.map_reduce(paired, [], fn
        {attrs, nil}, kept ->
          {attrs, kept}

        {attrs, %Section{} = section}, kept ->
          if MapSet.member?(changeable, section.id) do
            {attrs, kept}
          else
            stored = stored_attrs(section)
            kept = if same?(attrs, stored), do: kept, else: [section.kind | kept]
            {stored, kept}
          end
      end)

    restored =
      unpaired_existing
      |> Enum.reject(&MapSet.member?(changeable, &1.id))
      |> Enum.sort_by(& &1.position)

    sections =
      Enum.reduce(restored, merged, fn section, acc ->
        List.insert_at(acc, min(section.position, length(acc)), stored_attrs(section))
      end)

    {sections, Enum.reverse(kept) ++ Enum.map(restored, & &1.kind)}
  end

  @doc "False for praise markers, which ask for nothing to change."
  def asks_change?(%Marker{kind: kind}), do: kind not in @praise

  # Does this marker sit on this stored section?
  defp targets?(%Marker{target: "illustration", media_id: media_id}, %Section{} = section) do
    not is_nil(media_id) and section.media_id == media_id
  end

  defp targets?(%Marker{section_kind: nil}, _section), do: true

  defp targets?(%Marker{target: "section"} = m, %Section{} = section) do
    section.kind == m.section_kind and
      (is_nil(m.section_position) or section.position == m.section_position)
  end

  defp targets?(%Marker{target: "text"} = m, %Section{} = section) do
    section.kind == m.section_kind and
      (section.position == m.section_position or
         (m.quote not in [nil, ""] and String.contains?(section.body || "", m.quote)))
  end

  defp targets?(_marker, _section), do: false

  # A section carrying media pairs with the stored section holding the same
  # media; the rest pair by kind in order (the i-th incoming description with
  # the i-th stored one). Position is dropped so the final list order is the
  # position (replace_sections indexes it).
  defp pair_by_kind(existing, incoming) do
    {by_media, left} =
      Enum.map_reduce(incoming, existing, fn attrs, left ->
        match =
          attrs["media_id"] &&
            Enum.find(left, &(&1.kind == attrs["kind"] and &1.media_id == attrs["media_id"]))

        if match, do: {{attrs, match}, List.delete(left, match)}, else: {{attrs, nil}, left}
      end)

    {paired, remaining} =
      Enum.map_reduce(by_media, Enum.group_by(left, & &1.kind), fn
        {attrs, nil}, by_kind ->
          case Map.get(by_kind, attrs["kind"], []) do
            [section | rest] -> {{attrs, section}, Map.put(by_kind, attrs["kind"], rest)}
            [] -> {{attrs, nil}, by_kind}
          end

        pair, by_kind ->
          {pair, by_kind}
      end)

    {paired, remaining |> Map.values() |> List.flatten()}
  end

  defp normalize(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.delete("position")
  end

  defp stored_attrs(%Section{} = s) do
    %{
      "kind" => s.kind,
      "title" => s.title,
      "body" => s.body,
      "media_id" => s.media_id,
      "metadata" => s.metadata || %{}
    }
  end

  defp same?(attrs, stored) do
    Enum.all?(["title", "body", "media_id"], &(Map.get(attrs, &1) == stored[&1])) and
      Map.get(attrs, "metadata", %{}) == stored["metadata"]
  end
end
