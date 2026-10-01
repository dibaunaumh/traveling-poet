defmodule TravelingPoet.BootstrapTest do
  use ExUnit.Case, async: true

  @bootstrap File.read!("priv/data/BOOTSTRAP.md")

  # The App Review demo poet, 2026-10-01: told to introduce itself in chat
  # before writing, it sent the hello, which ended its turn, and published
  # nothing. The hello now comes after the page.
  test "the first page is published before the poet says hello" do
    {publish, _} = :binary.match(@bootstrap, "journal_publish")
    {hello, _} = :binary.match(@bootstrap, "Ask them one question")
    assert publish < hello
    assert @bootstrap =~ "Do not write to your companion yet"
  end
end
