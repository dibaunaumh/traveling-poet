defmodule TravelingPoet.Evals.BlindTests do
  @moduledoc """
  Blind writing tests judged in the admin pages (`/admin/experiments`).

  A test is a writing-eval manifest (`TravelingPoet.Evals.Writing`, the
  `manifest.json` of one run) loaded onto the server, plus the judge's votes.
  The static `page/index.html` keeps votes in one browser and needs a file
  export; this keeps them in the database, so a test can be judged on a phone
  and revealed where it was judged. The votes have the static page's export
  shape, so `Writing.tally/2` reads either.

  Loading one on production, after copying the manifest up with
  `fly ssh sftp put`:

      BlindTests.import_file("/tmp/manifest.json", "Shadow week")

  `days/1` never says which candidate wrote which page: only letters reach
  the page, and the candidates come out only through `tally/1`.
  """

  import Ecto.Query

  alias TravelingPoet.Evals.BlindTests.BlindTest
  alias TravelingPoet.Evals.Writing
  alias TravelingPoet.Evals.Writing.Page
  alias TravelingPoet.Repo

  @marks ~w(publishable gibberish preachy)

  def marks, do: @marks

  def list, do: Repo.all(from t in BlindTest, order_by: [desc: t.inserted_at])

  def get(name), do: Repo.get_by(BlindTest, name: name)

  @doc "Loads a manifest file as a test named after its run id; a reload keeps the votes."
  def import_file(path, title \\ nil) do
    path |> File.read!() |> Jason.decode!() |> import_manifest(title)
  end

  def import_manifest(%{"run_id" => name} = manifest, title \\ nil) do
    case get(name) do
      nil -> %BlindTest{votes: %{}}
      test -> test
    end
    |> BlindTest.changeset(%{name: name, title: title || name, manifest: manifest})
    |> Repo.insert_or_update()
  end

  @doc """
  The days as the judge sees them: `%{id, poet, language, date, excursion,
  pages: [%{letter, title, teaser, sections, notes} | %{letter, missing}]}`.
  """
  def days(%BlindTest{manifest: m}) do
    results = Map.new(m["results"], &{{&1["day_id"], &1["candidate_id"]}, &1})

    Enum.map(m["days"], fn d ->
      %{
        id: d["id"],
        poet: d["poet"],
        language: d["language"],
        date: d["entry_date"],
        excursion: d["excursion"],
        pages:
          m["blind"]
          |> Map.get(d["id"], %{})
          |> Enum.sort()
          |> Enum.map(fn {letter, cid} -> card(letter, results[{d["id"], cid}]) end)
      }
    end)
  end

  defp card(letter, %{"status" => "ok", "page" => page} = r) do
    %{
      letter: letter,
      title: page["title"],
      teaser: page["teaser"],
      sections: Enum.map(page["sections"] || [], &Map.take(&1, ~w(kind title body))),
      notes: Page.notes(r["metrics"] || %{}, r["judge"])
    }
  end

  defp card(letter, r), do: %{letter: letter, missing: (r && r["error"]) || "not written"}

  @doc "One day's vote: `%{\"best\" => letter | nil, \"publishable\" => [..], ...}`."
  def vote(%BlindTest{votes: votes}, day_id) do
    Map.merge(
      %{"best" => nil, "publishable" => [], "gibberish" => [], "preachy" => []},
      votes[day_id] || %{}
    )
  end

  @doc "Picks the day's best page; picking it again clears it."
  def set_best(test, day_id, letter) do
    with :ok <- known(test, day_id, letter) do
      v = vote(test, day_id)
      put_vote(test, day_id, %{v | "best" => if(v["best"] == letter, do: nil, else: letter)})
    end
  end

  @doc "Turns one mark (publishable, gibberish, preachy) on or off for a page."
  def toggle_mark(test, day_id, letter, mark) when mark in @marks do
    with :ok <- known(test, day_id, letter) do
      v = vote(test, day_id)

      marked =
        if letter in v[mark],
          do: List.delete(v[mark], letter),
          else: Enum.sort([letter | v[mark]])

      put_vote(test, day_id, Map.put(v, mark, marked))
    end
  end

  def toggle_mark(_test, _day_id, _letter, _mark), do: {:error, :unknown_mark}

  defp known(%BlindTest{manifest: m}, day_id, letter) do
    if Map.has_key?(get_in(m, ["blind", day_id]) || %{}, letter),
      do: :ok,
      else: {:error, :unknown_page}
  end

  defp put_vote(test, day_id, vote) do
    test
    |> BlindTest.changeset(%{votes: Map.put(test.votes, day_id, vote)})
    |> Repo.update()
  end

  @doc "How many days have a best page picked."
  def judged(%BlindTest{votes: votes}), do: Enum.count(votes, fn {_, v} -> v["best"] != nil end)

  @doc "The reveal: one row per candidate, as `Writing.tally/2` counts it."
  def tally(%BlindTest{manifest: m, votes: votes}) do
    judged = for {day, v} <- votes, v["best"] != nil, into: %{}, do: {day, v}
    Writing.tally(m, %{"votes" => judged})
  end
end
