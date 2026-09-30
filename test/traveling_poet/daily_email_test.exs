defmodule TravelingPoet.DailyEmailTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Accounts, Email, Journal}
  alias TravelingPoet.Email.{EntryEmail, Notifier}

  setup do
    user = user_fixture(%{email: "mani@example.com"})
    poet = poet_fixture(user, %{name: "Kenji Driftwood", is_public: false})

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-09-30], %{
        title: "The scramble & the silence",
        teaser: "Fourteen million people went around me.",
        place_name: "Tokyo"
      })

    drawing = media_fixture(poet, %{journal_entry_id: entry.id})
    {:ok, _} = Journal.replace_sections(entry, [%{kind: "illustration", media_id: drawing.id}])
    {:ok, entry} = Journal.publish_entry(entry)

    Application.put_env(:traveling_poet, :resend_api_key, "re_test")
    on_exit(fn -> Application.delete_env(:traveling_poet, :resend_api_key) end)

    %{user: user, poet: poet, entry: entry, drawing: drawing}
  end

  defp capture_resend do
    test = self()

    Req.Test.stub(Email, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        test,
        {:resend, conn.request_path, Plug.Conn.get_req_header(conn, "authorization"),
         Jason.decode!(body)}
      )

      Req.Test.json(conn, %{"id" => "email-1"})
    end)
  end

  test "the page email names the day and place, links the page and a signed drawing, and can be stopped",
       %{user: user, poet: poet, entry: entry} do
    capture_resend()
    Notifier.send_entry(poet.id, entry.id)

    assert_receive {:resend, "/emails", ["Bearer re_test"], sent}
    assert sent["to"] == ["mani@example.com"]
    assert sent["subject"] =~ "Kenji Driftwood in Tokyo: The scramble & the silence"
    assert sent["html"] =~ "Fourteen million people went around me."
    # escaped in the html, plain in the text
    assert sent["html"] =~ "The scramble &amp; the silence"
    assert sent["html"] =~ "/journal/2026-09-30"
    assert sent["html"] =~ ~r{/media/\d+\?sig=}
    assert sent["text"] =~ "Read today's page: "
    assert sent["headers"]["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"

    assert [_, token] =
             Regex.run(~r{/email/unsubscribe/([^>]+)>}, sent["headers"]["List-Unsubscribe"])

    assert {:ok, user.id} == Notifier.verify_unsubscribe(token)
  end

  test "no email for a reader who turned it off, or at a Hide My Email address",
       %{user: user, poet: poet, entry: entry} do
    Req.Test.stub(Email, fn _conn -> flunk("nothing should be sent") end)

    {:ok, _} = Accounts.update_user(user, %{email_notify: false})
    assert Notifier.send_entry(poet.id, entry.id) == :skipped

    {:ok, _} =
      Accounts.update_user(user, %{email_notify: true, email: "x1y2@privaterelay.appleid.com"})

    assert Notifier.send_entry(poet.id, entry.id) == :skipped
  end

  test "a Resend error is reported, never raised", %{poet: poet, entry: entry} do
    Req.Test.stub(
      Email,
      &(&1 |> Plug.Conn.put_status(422) |> Req.Test.json(%{"message" => "bad"}))
    )

    assert Notifier.send_entry(poet.id, entry.id) == {:error, {:http, 422}}
  end

  test "the drawing signature opens that one drawing only", %{poet: poet, drawing: drawing} do
    sig = Notifier.media_sig(drawing.id)
    conn = Phoenix.ConnTest.build_conn(:get, "/media/#{drawing.id}", %{"sig" => sig})
    conn = %{conn | params: %{"sig" => sig}}

    assert TravelingPoetWeb.MediaController.authorize(conn, poet, drawing.id) == :ok
    assert TravelingPoetWeb.MediaController.authorize(conn, poet, drawing.id + 1) == :forbidden

    assert TravelingPoetWeb.MediaController.authorize(%{conn | params: %{}}, poet, drawing.id) ==
             :forbidden
  end

  test "EntryEmail leaves the drawing out when there is none", %{
    user: user,
    poet: poet,
    entry: entry
  } do
    email =
      EntryEmail.build(%{
        user: user,
        poet: poet,
        entry: entry,
        day: 1,
        drawing_url: nil,
        page_url: "https://poet.travel/journal/2026-09-30",
        unsubscribe_url: "https://poet.travel/email/unsubscribe/t"
      })

    refute email.html =~ "<img"
    assert email.subject == "Day 1 · Kenji Driftwood in Tokyo: The scramble & the silence"
  end
end
