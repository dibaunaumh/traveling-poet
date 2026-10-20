defmodule TravelingPoetWeb.FullPageEmailTest do
  @moduledoc """
  The daily email can carry the whole page (card-124): a reader asked to
  read the page in the mail itself. Off by default, so everyone else keeps
  the short note that stays out of Gmail's Promotions tab.
  """
  use TravelingPoetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Email, Journal}
  alias TravelingPoet.Email.Notifier, as: EmailNotifier

  setup do
    Application.put_env(:traveling_poet, :resend_api_key, "re_test")
    on_exit(fn -> Application.delete_env(:traveling_poet, :resend_api_key) end)

    test_pid = self()

    Req.Test.stub(Email, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:resend, Jason.decode!(body)})
      Req.Test.json(conn, %{"id" => "email-1"})
    end)

    user = user_fixture(%{email: "nam-reader@example.com"})
    poet = poet_fixture(user, %{name: "Nam", is_public: false})

    entry =
      published_entry_fixture(poet, %{
        title: "The woolly rugby scrum",
        teaser: "Sheep roped neck to neck.",
        entry_date: ~D[2026-10-20]
      })

    main = media_fixture(poet, %{journal_entry_id: entry.id, alt_text: "The Tuesday market"})

    spot =
      media_fixture(poet, %{
        journal_entry_id: entry.id,
        kind: "spot",
        alt_text: "a bundle of wool"
      })

    {:ok, _} =
      Journal.replace_sections(entry, [
        %{
          kind: "description",
          body:
            "The animal market spreads across the field.\n\n" <>
              "![a bundle of wool](/media/#{spot.id})\n\nRaw wool is sold in cream bundles. " <>
              "![a photo found online](https://example.com/photo.jpg)"
        },
        %{kind: "illustration", media_id: main.id},
        %{
          kind: "poem",
          title: "Asinas",
          body: "Tuesday's name\nis the road that starts tomorrow."
        }
      ])

    place_fixture(poet, entry, %{
      name: "Amazigh Museum",
      category: "museum",
      address: "Place Taza"
    })

    %{user: user, poet: poet, entry: entry, main: main, spot: spot}
  end

  test "off by default: the note, with the teaser and one drawing", %{poet: poet, entry: entry} do
    EmailNotifier.send_entry(poet.id, entry.id)
    assert_receive {:resend, sent}
    assert sent["html"] =~ "Sheep roped neck to neck."
    assert sent["html"] =~ "Read today's page"
    refute sent["html"] =~ "The animal market"
    refute sent["html"] =~ "Amazigh Museum"
  end

  test "on: the prose, the poem, the drawings on signed links, and the places",
       %{user: user, poet: poet, entry: entry, main: main, spot: spot} do
    {:ok, _} = Accounts.update_user(user, %{email_full_page: true})
    EmailNotifier.send_entry(poet.id, entry.id)
    assert_receive {:resend, sent}
    html = sent["html"]

    assert html =~ "<b>The woolly rugby scrum</b>"
    assert html =~ "The animal market spreads across the field."
    assert html =~ "<b>Asinas</b>"
    assert html =~ ~s(style="white-space:pre-line")
    assert html =~ "is the road that starts tomorrow."
    assert html =~ "Open today's page"
    refute html =~ "Sheep roped neck to neck."

    # every drawing is signed and absolute, so a private journal's show in a mail app
    assert html =~ ~r{src="http://[^"]+/media/#{main.id}\?sig=[^"]+"}
    assert html =~ ~r{src="http://[^"]+/media/#{spot.id}\?sig=[^"]+"}
    # a photo from the web collapses to its words, as on the page
    refute html =~ "example.com/photo.jpg"
    assert html =~ "a photo found online"

    assert html =~ "Amazigh Museum"
    assert html =~ "Place Taza"
    assert html =~ "Open the guide"

    assert sent["text"] =~ "The animal market spreads across the field."
    assert sent["text"] =~ "Asinas"
    assert sent["text"] =~ "- Amazigh Museum"
    refute sent["text"] =~ "Sheep roped neck to neck."
  end

  test "the drawing links carry the signature a mail app needs on a private journal",
       %{conn: conn, user: user, poet: poet, entry: entry, main: main} do
    {:ok, _} = Accounts.update_user(user, %{email_full_page: true})
    EmailNotifier.send_entry(poet.id, entry.id)
    assert_receive {:resend, sent}
    [_, sig] = Regex.run(~r{/media/#{main.id}\?sig=([^"]+)"}, sent["html"])

    assert EmailNotifier.verify_media_sig(sig, main.id)
    refute EmailNotifier.verify_media_sig(sig, main.id + 1)
    # without it, a stranger is refused (the bytes themselves live in storage)
    assert conn |> get(~p"/media/#{main.id}") |> response(403)
  end

  test "Settings offers the whole page under the email switch", %{conn: conn, user: user} do
    {:ok, user} = Accounts.update_user(user, %{onboarding_completed: true})

    {:ok, view, html} =
      conn |> Plug.Test.init_test_session(%{user_id: user.id}) |> live(~p"/settings")

    assert html =~ "Send the whole page"

    view
    |> form("#email-notify-form", %{"email_notify" => "true", "email_full_page" => "true"})
    |> render_change()

    assert Accounts.get_user!(user.id).email_full_page

    view
    |> form("#email-notify-form", %{"email_notify" => "true", "email_full_page" => "false"})
    |> render_change()

    refute Accounts.get_user!(user.id).email_full_page
  end
end
