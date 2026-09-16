defmodule TravelingPoetWeb.SettingsLiveTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.Credits

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  test "shows balance, runway and packs; no header pill when healthy", %{conn: conn} do
    user = user_fixture(%{credits: 12, onboarding_completed: true})
    _poet = poet_fixture(user)

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ ~s(id="credits-balance")
    assert html =~ "12"
    assert html =~ "≈ 12 days of travel"
    assert html =~ "300 credits"
    assert html =~ "$100"
    assert html =~ "test mode"
    refute html =~ "Running low on credits"
  end

  test "low balance shows the warning and the header pill", %{conn: conn} do
    user = user_fixture(%{credits: 2, onboarding_completed: true})
    _poet = poet_fixture(user)

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ "Running low on credits"
    assert html =~ "≈ 2 days of travel"
  end

  test "balance updates live after a purchase", %{conn: conn} do
    user = user_fixture(%{credits: 1, onboarding_completed: true})
    _poet = poet_fixture(user)

    {:ok, view, _html} = live(sign_in(conn, user), ~p"/settings")
    {:ok, _} = Credits.purchase(user, "p10", "test:1")
    assert render(view) =~ "≈ 11 days of travel"
    assert render(view) =~ "Purchase"
  end

  describe "a composed book edition" do
    alias TravelingPoet.{Books, Journal}
    alias TravelingPoet.Books.Composer

    defp journey(attrs) do
      user = agent_user_fixture(Map.merge(%{onboarding_completed: true}, attrs))
      poet = poet_fixture(user, %{name: "Wren"})
      published_entry_fixture(poet, %{title: "Trams"})
      {user, poet}
    end

    test "shows the cost; asking charges it and shows the poet composing", %{conn: conn} do
      {user, poet} = journey(%{credits: 10})

      {:ok, view, html} = live(sign_in(conn, user), ~p"/settings")
      assert html =~ "Ask Wren to compose it"
      # base 2 + 1 chapter (test pricing)
      assert html =~ "(3 credits)"

      html = view |> element("#compose-book-button") |> render_click()
      assert html =~ "Wren is composing your book"
      assert html =~ ~s(id="book-composing")
      refute html =~ ~s(id="compose-book-button")
      assert html =~ "≈ 7 days of travel"
      assert html =~ "Composed book"

      # the poet writes, the turn ends: the page updates by itself
      [edition] = Books.current_edition(poet) |> List.wrap()
      {:ok, _, _} = Books.put_matter(poet, %{"foreword" => "Before the road."})
      Composer.finish(edition.id, {:ok, "done"})

      html = render(view)
      assert html =~ ~s(id="book-ready")
      assert html =~ "Compose it again"
    end

    test "a failed composition says nothing was charged", %{conn: conn} do
      {user, poet} = journey(%{credits: 10})
      {:ok, edition} = Books.request_composition(user, poet)
      Composer.finish(edition.id, {:timeout, ""})

      {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
      assert html =~ "nothing was charged"
      assert html =~ "Ask Wren to compose it"
    end

    test "too few credits disables the button and says why; exempt accounts see free", %{
      conn: conn
    } do
      {user, _poet} = journey(%{credits: 2})
      {:ok, view, html} = live(sign_in(conn, user), ~p"/settings")
      assert html =~ "Not enough credits for a composed edition."
      assert has_element?(view, "#compose-book-button[disabled]")

      {exempt, _poet} = journey(%{quota_exempt: true})
      {:ok, _view, html} = live(sign_in(build_conn(), exempt), ~p"/settings")
      assert html =~ "(free)"
    end

    test "no published pages means no composition to offer", %{conn: conn} do
      user = agent_user_fixture(%{onboarding_completed: true, credits: 10})
      _poet = poet_fixture(user)
      {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
      refute html =~ ~s(id="compose-book")
      _ = Journal
    end
  end

  test "exhausted balance shows the resting note", %{conn: conn} do
    user = user_fixture(%{onboarding_completed: true})
    _poet = poet_fixture(user)

    {:ok, _view, html} = live(sign_in(conn, user), ~p"/settings")
    assert html =~ "resting until you top up"
  end
end

defmodule TravelingPoetWeb.SettingsLiveEditTest do
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Poets}

  defp sign_in(conn, user), do: Plug.Test.init_test_session(conn, %{user_id: user.id})

  defp mount(conn) do
    user = user_fixture(%{onboarding_completed: true})
    poet = poet_fixture(user)
    {:ok, view, html} = live(sign_in(conn, user), ~p"/settings")
    {user, poet, view, html}
  end

  test "renames the poet; a blank name keeps the current one and the slug", %{conn: conn} do
    {_user, poet, view, _html} = mount(conn)

    view |> form("#poet-settings-form", %{"poet_name" => "Señora Tinta"}) |> render_change()
    updated = Poets.get_poet!(poet.id)
    assert updated.name == "Señora Tinta"
    assert updated.slug == poet.slug

    html = view |> form("#poet-settings-form", %{"poet_name" => "  "}) |> render_change()
    refute html =~ "Could not save"
    assert Poets.get_poet!(poet.id).name == "Señora Tinta"
  end

  test "renames the reader, ignoring blanks", %{conn: conn} do
    {user, _poet, view, _html} = mount(conn)

    view |> form("#user-settings-form", %{"name" => "Udi"}) |> render_change()
    assert Accounts.get_user!(user.id).name == "Udi"

    view |> form("#user-settings-form", %{"name" => ""}) |> render_change()
    assert Accounts.get_user!(user.id).name == "Udi"
  end

  test "toggles curated books and adds/removes a free-text one", %{conn: conn} do
    {_user, poet, view, _html} = mount(conn)

    html = render_click(view, "toggle_book", %{"idx" => "0"})
    assert html =~ ~r/id="book-chip-0"[^>]*btn-primary/s
    [item] = Poets.get_poet!(poet.id).currently_reading["items"]
    assert item["title"] == "The Timeless Way of Building"
    assert item["author"] == "Christopher Alexander"

    render_click(view, "toggle_book", %{"idx" => "0"})
    assert Poets.get_poet!(poet.id).currently_reading["items"] == []

    html = view |> form("#add-book-form", %{"title" => "Invisible Cities"}) |> render_submit()
    assert html =~ "Invisible Cities"

    assert [%{"title" => "Invisible Cities", "author" => ""}] =
             Poets.get_poet!(poet.id).currently_reading["items"]

    html = render_click(view, "remove_book", %{"title" => "Invisible Cities"})
    refute html =~ "Invisible Cities"
    assert Poets.get_poet!(poet.id).currently_reading["items"] == []
  end
end
