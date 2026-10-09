defmodule TravelingPoet.SkillFilesTest do
  use ExUnit.Case, async: true

  alias TravelingPoet.Provisioner

  # One poet, 2026-09-30: the 30 KB daily skill, re-read in chunks,
  # overflowed the model's context before the poet wrote anything. The day
  # kinds most runs never see live in their own files.
  test "the daily skill stays small and hands day-specific parts to their own files" do
    files = Provisioner.skill_files()
    skill = Map.fetch!(files, "travel-and-journal/SKILL.md")

    assert byte_size(skill) < 24_000

    for day_file <- ~w(scout.md excursion.md asking.md stay.md) do
      assert Map.has_key?(files, "travel-and-journal/#{day_file}"), "#{day_file} not shipped"
      assert skill =~ "skills/travel-and-journal/#{day_file}"
    end

    assert skill =~ "Read this file once."
  end

  test "each day file carries the sections it took" do
    files = Provisioner.skill_files()
    assert files["travel-and-journal/excursion.md"] =~ "## 2d. Taste day"
    assert files["travel-and-journal/scout.md"] =~ "itinerary_stop_id"
    assert files["travel-and-journal/asking.md"] =~ "`ask_reader`"
  end

  # Spaces phase 2: the poet is told, in a few lines, that a dish, an artwork
  # or a person can sit in the list with a link, and a historic place an era.
  test "the skill tells the poet about kinds, links and era without growing" do
    files = Provisioner.skill_files()
    skill = files["travel-and-journal/SKILL.md"]
    assert skill =~ "`kind` (dish, artwork,\n  person)"
    assert skill =~ "`links`"
    assert skill =~ "`era`"
    assert files["travel-and-journal/excursion.md"] =~ "person for an artist"
  end
end
