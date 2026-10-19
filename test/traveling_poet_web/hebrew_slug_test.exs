defmodule TravelingPoetWeb.HebrewSlugTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  test "a poet with a Hebrew name gets a Hebrew address that opens", %{conn: conn} do
    poet = poet_fixture(user_fixture(%{locale: "he"}), %{name: "נועם צוף", is_public: true})
    assert poet.slug == "נועם-צוף"

    assert conn |> get(~p"/p/#{poet.slug}") |> html_response(200) =~ "נועם צוף"
  end
end
