defmodule TravelingPoetWeb.PoetLanguageTest do
  @moduledoc """
  The poet writes in its reader's language (card-101): the context names it on
  every run, a chat message carries it, and a Hebrew reader meets a poet set
  up in Hebrew.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Asks}
  alias TravelingPoet.Poets.Presets

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp context(conn, user) do
    conn
    |> put_req_header("authorization", "Bearer #{user.agent_api_token}")
    |> get(~p"/api/agent/context")
    |> json_response(200)
  end

  test "the context names the reader's current language", %{conn: conn} do
    user = agent_user_fixture()
    _poet = poet_fixture(user)

    assert %{"language" => "en", "language_name" => "English"} = context(conn, user)["poet"]

    {:ok, user} = Accounts.set_locale(user, "he")

    assert %{"language" => "he", "language_name" => "Hebrew"} =
             context(build_conn(), user)["poet"]
  end

  test "a Hebrew reader's chat message tells the poet which language to answer in" do
    he = user_fixture(%{locale: "he"})
    en = user_fixture()

    assert Asks.frame_reply(he.id, "שלום") ==
             "[From the app: write to them in Hebrew.]\n\nשלום"

    assert Asks.frame_reply(en.id, "hello") == "hello"
  end

  describe "Hebrew presets" do
    test "match the English ones voice for voice, in copy rules" do
      assert length(Presets.personalities("he")) == length(Presets.personalities("en"))

      for p <- Presets.personalities("he") do
        assert p["label"] =~ ~r/\p{Hebrew}/u
        assert p["text"] =~ ~r/\p{Hebrew}/u
        assert String.length(p["sample"]) > 100, p["label"]
        refute p["sample"] =~ ~r/[\x{2014}\x{2013}]/u, "dash in #{p["label"]}"
      end

      assert Enum.all?(Presets.names("he"), &(&1 =~ ~r/\p{Hebrew}/u))
      assert Presets.interests("he") != Presets.interests("en")
      assert Presets.names("xx") == Presets.names("en")
    end

    test "onboarding a Hebrew reader pre-fills a Hebrew poet", %{conn: conn} do
      user = user_fixture(%{locale: "he"})
      {:ok, _view, html} = live(sign_in(conn, user), ~p"/onboarding")

      assert Enum.any?(Presets.names("he"), &(html =~ &1))
      assert Enum.any?(Presets.personalities("he"), &(html =~ &1["label"]))
      refute Enum.any?(Presets.personalities("en"), &(html =~ &1["label"]))
    end
  end
end
