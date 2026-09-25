defmodule TravelingPoet.Journal.PageSubjects do
  @moduledoc """
  What a whole page is about, derived from what is tagged on it: its
  paragraphs (`paragraph_subjects`), its places and its finds, all on the
  one subject tree (`Guide.PlaceTopics`), plus the reader's topic on an
  excursion day. Nothing is stored: a page's subjects follow its parts, so
  they can never disagree with them.

  Each part counts once for its first topic and half for its second, and an
  excursion's own topic counts as much as two parts, since the whole day
  was spent on it. `of_entry/1` returns the page's leaf topics, heaviest
  first, with each one's `share` of the page; `at_depth/2` rolls them up to
  a subject (depth 1) or a subtopic (depth 2).

  Uses: a reaction to a whole page (love, not for me) is spread over its
  subjects by share; a subject picked in Discover can show the pages mainly
  about it.
  """

  import Ecto.Query

  alias TravelingPoet.Guide.Place
  alias TravelingPoet.Journal.ParagraphSubject
  alias TravelingPoet.Repo
  alias TravelingPoet.Topics.{Excursion, Find, Topic}

  @excursion_weight 2.0

  @doc "`[%{path, weight, share}]` for an entry, heaviest first; [] when nothing is tagged."
  def of_entry(entry_id) do
    weights =
      (pairs(ParagraphSubject, entry_id) ++ pairs(Place, entry_id) ++ pairs(Find, entry_id))
      |> Enum.flat_map(fn {a, b} -> [{a, 1.0}, {b, 0.5}] end)
      |> Enum.concat(excursion(entry_id))
      |> Enum.reject(fn {path, _w} -> is_nil(path) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {path, ws} -> {path, Enum.sum(ws)} end)

    total = weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()

    weights
    |> Enum.map(fn {path, w} -> %{path: path, weight: w, share: w / total} end)
    |> Enum.sort_by(&{-&1.weight, &1.path})
  end

  @doc """
  The same subjects rolled up to `depth` (1: "music-and-performance", 2:
  "music-and-performance/music"), heaviest first.
  """
  def at_depth(subjects, depth) when depth in 1..3 do
    subjects
    |> Enum.group_by(&(&1.path |> String.split("/") |> Enum.take(depth) |> Enum.join("/")))
    |> Enum.map(fn {path, parts} ->
      %{
        path: path,
        weight: parts |> Enum.map(& &1.weight) |> Enum.sum(),
        share: parts |> Enum.map(& &1.share) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{-&1.weight, &1.path})
  end

  defp pairs(schema, entry_id) do
    schema
    |> where([x], x.journal_entry_id == ^entry_id and not is_nil(x.topic))
    |> select([x], {x.topic, x.second_topic})
    |> Repo.all()
  end

  defp excursion(entry_id) do
    Excursion
    |> join(:inner, [x], t in Topic, on: t.id == x.topic_id)
    |> where([x], x.journal_entry_id == ^entry_id)
    |> select([_x, t], {t.subject, t.second_subject})
    |> Repo.all()
    |> Enum.flat_map(fn {a, b} -> [{a, @excursion_weight}, {b, @excursion_weight / 2}] end)
  end
end
