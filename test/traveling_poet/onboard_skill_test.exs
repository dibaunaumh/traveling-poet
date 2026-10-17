defmodule TravelingPoet.OnboardSkillTest do
  use ExUnit.Case, async: true

  @skill File.read!("priv/data/skills/onboard/SKILL.md")

  # The App Review demo poet, 2026-10-01: told to introduce itself in chat
  # before writing, it sent the hello, which ended its turn, and published
  # nothing. The hello comes after the page.
  test "the first page is published before the poet says hello" do
    {publish, _} = :binary.match(@skill, "journal_publish")
    {hello, _} = :binary.match(@skill, "Ask them one question")
    assert publish < hello
    assert @skill =~ "Do not write to your companion yet"
  end

  # OpenClaw 2026.10 removes BOOTSTRAP.md after the first session, finished
  # or not; three poets of 2026-10-17 lost their ritual that way.
  test "the ritual is keyed on the app's set_out, not on a workspace file" do
    assert @skill =~ "`set_out`"
    assert @skill =~ "`self_portrait`"
    refute @skill =~ "BOOTSTRAP"
  end
end
