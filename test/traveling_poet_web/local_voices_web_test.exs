defmodule TravelingPoetWeb.LocalVoicesWebTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, LocalVoices, Repo}
  alias TravelingPoet.LocalVoices.Question

  @lisbon %{home_place_name: "Lisbon, Portugal", home_lat: 38.71, home_lng: -9.14}

  defp signed_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  setup do
    poet = poet_fixture(agent_user_fixture(), %{name: "Wren", status: "active"})

    local =
      user_fixture(
        Map.merge(@lisbon, %{name: "Dana Levi", onboarding_completed: true, local_voice: true})
      )

    %{poet: poet, local: local}
  end

  describe "the answer form" do
    test "the local answers, and the answer is kept", %{conn: conn, poet: poet, local: local} do
      q = LocalVoices.maybe_ask(poet, DateTime.utc_now())
      {:ok, view, html} = live(signed_in(conn, local), ~p"/locals/#{q.id}")

      assert html =~ "Wren is in Lisbon"
      assert html =~ "From a reader who lives in Lisbon"

      html =
        view
        |> form("#local-answer", local: %{answer: "The miradouro at dusk."})
        |> render_submit()

      assert html =~ ~s(id="local-answered")
      assert Repo.get(Question, q.id).answer == "The miradouro at dusk."
    end

    test "not this time closes it", %{conn: conn, poet: poet, local: local} do
      q = LocalVoices.maybe_ask(poet, DateTime.utc_now())
      {:ok, view, _html} = live(signed_in(conn, local), ~p"/locals/#{q.id}")

      assert view |> element("#local-decline") |> render_click() =~ ~s(id="local-declined")
      assert Repo.get(Question, q.id).status == "declined"
    end

    test "nobody else can open it", %{conn: conn, poet: poet} do
      q = LocalVoices.maybe_ask(poet, DateTime.utc_now())
      stranger = user_fixture(%{onboarding_completed: true})

      assert {:error, {:live_redirect, %{to: "/journal"}}} =
               live(signed_in(conn, stranger), ~p"/locals/#{q.id}")
    end
  end

  describe "saying yes" do
    test "Settings: beside the home city, with the credit to choose", %{conn: conn} do
      reader =
        agent_user_fixture(Map.merge(@lisbon, %{onboarding_completed: true, name: "Noa Bar"}))

      poet_fixture(reader, %{name: "Tobias"})

      {:ok, view, html} = live(signed_in(conn, reader), ~p"/settings")
      assert html =~ ~s(id="local-voice-setting")
      refute html =~ ~s(id="local-voice-credit")

      html = view |> element("#local-voice-toggle") |> render_click()
      assert Accounts.get_user!(reader.id).local_voice
      assert html =~ "By my first name, Noa"
      assert html =~ "As Tobias&#39;s companion"

      view |> element("#local-voice-credit") |> render_change(%{credit: "poet"})
      assert Accounts.get_user!(reader.id).local_voice_credit == "poet"

      view |> element("#local-voice-toggle") |> render_click()
      refute Accounts.get_user!(reader.id).local_voice
    end

    test "onboarding asks with the home city, off unless ticked", %{conn: conn} do
      Application.put_env(:traveling_poet, :destination_search, fn _ ->
        {:ok,
         [
           %{
             place_name: "Lisboa, Portugal",
             kind: "city",
             city: "Lisboa",
             lat: 38.72,
             lng: -9.14,
             country_code: "pt"
           }
         ]}
      end)

      on_exit(fn -> Application.delete_env(:traveling_poet, :destination_search) end)

      reader = user_fixture()
      {:ok, view, _html} = live(signed_in(conn, reader), ~p"/onboarding")
      render_click(view, "next", %{})
      render_click(view, "next", %{})
      view |> element("#onboarding-home-search") |> render_submit(%{home_query: "Lisbon"})
      html = view |> element("#onboarding-home-0") |> render_click()
      assert html =~ ~s(id="onboarding-local-voice")

      view |> element("#onboarding-local-voice-toggle") |> render_click()
      view |> element("#onboarding-local-voice-credit") |> render_change(%{credit: "name"})
      render_click(view, "create_poet", %{})

      reader = Accounts.get_user!(reader.id)
      assert reader.local_voice
      assert reader.local_voice_credit == "name"
    end
  end
end
