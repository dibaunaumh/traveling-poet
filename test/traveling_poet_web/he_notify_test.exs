defmodule TravelingPoetWeb.HeNotifyTest do
  @moduledoc """
  The notes that reach a reader outside the app (card-101): the push and
  APNs payloads, the daily page email, the Telegram notes and the bot's own
  replies. Nothing sets a language for a background sender, so each is built
  in its reader's `users.locale`: Hebrew for a Hebrew reader, today's
  English for everyone else.
  """
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.{Apns, Email, Journal, Locale, WebPush}
  alias TravelingPoet.Email.Notifier, as: EmailNotifier
  alias TravelingPoet.Telegram.{Notifier, Poller}

  @token String.duplicate("ab12", 16)

  defp reader(locale, name) do
    user = user_fixture(%{locale: locale, email: "#{name}@example.com"})
    poet = poet_fixture(user, %{name: name, is_public: false})

    {:ok, entry} =
      Journal.upsert_entry(poet.id, ~D[2026-10-12], %{
        title: "Fado",
        teaser: "Twelve strings, one ache.",
        place_name: "Lisbon",
        language: locale
      })

    {:ok, entry} = Journal.publish_entry(entry)
    %{user: user, poet: poet, entry: entry}
  end

  describe "a push to the iOS app" do
    setup do
      p8 = :public_key.generate_key({:namedCurve, :secp256r1})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:PrivateKeyInfo, p8)])

      for {k, v} <- [
            apple_team_id: "TEAM123456",
            apple_key_id: "KEY1234567",
            apple_private_key: pem,
            apple_bundle_id: "travel.poet.app"
          ],
          do: Application.put_env(:traveling_poet, k, v)

      Apns.forget_provider_token()

      on_exit(fn ->
        for k <- [:apple_team_id, :apple_key_id, :apple_private_key, :apple_bundle_id],
            do: Application.delete_env(:traveling_poet, k)

        Apns.forget_provider_token()
      end)

      test_pid = self()

      Req.Test.stub(TravelingPoet.Apns, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:apns, Jason.decode!(raw)})
        Req.Test.json(conn, %{})
      end)

      :ok
    end

    test "is in Hebrew for a Hebrew reader" do
      %{user: user, poet: poet, entry: entry} = reader("he", "Wren")
      {:ok, _} = Apns.register(user, @token, "sandbox")

      assert {1, 0} = WebPush.notify_entry(poet.id, entry.id)
      assert_received {:apns, body}
      assert body["aps"]["alert"]["title"] == "יום 1 · Wren ב-Lisbon"
      assert body["aps"]["alert"]["body"] == "Twelve strings, one ache."
    end

    test "is today's English for an English reader" do
      %{user: user, poet: poet, entry: entry} = reader("en", "Wren")
      {:ok, _} = Apns.register(user, @token, "sandbox")

      assert {1, 0} = WebPush.notify_entry(poet.id, entry.id)
      assert_received {:apns, body}
      assert body["aps"]["alert"]["title"] == "Day 1 · Wren in Lisbon"
    end
  end

  describe "the other push payloads, built for a Hebrew reader" do
    test "trips, the book, the PDF and a question" do
      %{user: user, poet: poet} = reader("he", "Wren")

      trip = %{
        id: 1,
        name: "Porto",
        start_date: ~D[2026-11-03],
        end_date: ~D[2026-11-09],
        scout_from: ~D[2026-10-30]
      }

      Locale.with_locale(user.locale, fn ->
        suggested = WebPush.trip_suggested_payload(poet, trip)
        assert suggested.title == "בלוח השנה שלכם יש טיול ל-Porto"
        assert suggested.body =~ "3 עד 9 בנובמבר"
        assert suggested.body =~ "לשלוח את Wren לסייר שם קודם?"

        changed = WebPush.trip_changed_payload(poet, trip)
        assert changed.title =~ "השתנו"
        assert changed.body =~ "30 באוקטובר"

        assert WebPush.book_ready_payload(poet, 1).title == "הספר שלכם עם Wren מוכן"
        assert WebPush.book_pdf_payload(poet, 1).body == "הקישו כדי להוריד."

        assert WebPush.question_payload(poet, %{id: 1, question: "?"}).title ==
                 "ל-Wren יש שאלה אליכם"
      end)
    end
  end

  describe "the daily page email" do
    setup do
      Application.put_env(:traveling_poet, :resend_api_key, "re_test")
      on_exit(fn -> Application.delete_env(:traveling_poet, :resend_api_key) end)

      test_pid = self()

      Req.Test.stub(Email, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:resend, Jason.decode!(body)})
        Req.Test.json(conn, %{"id" => "email-1"})
      end)

      :ok
    end

    test "is in Hebrew, right to left, for a Hebrew reader; the subject stays the page's title" do
      %{poet: poet, entry: entry} = reader("he", "Kenji")
      EmailNotifier.send_entry(poet.id, entry.id)

      assert_receive {:resend, sent}
      assert sent["subject"] == "Fado"
      assert sent["html"] =~ ~s(<html lang="he" dir="rtl">)
      assert sent["html"] =~ "יום 1 · Kenji ב-Lisbon"
      assert sent["html"] =~ "לקריאת העמוד של היום"
      assert sent["html"] =~ "להפסקת המיילים האלה"
      assert sent["html"] =~ "עמוד חדש מ-Kenji בכל יום."
      refute sent["html"] =~ "Read today's page"
      refute sent["html"] =~ "Stop these emails"
      assert sent["text"] =~ "לקריאת העמוד של היום: "
    end

    test "carries the page's own language on its title and teaser" do
      %{user: user, poet: poet, entry: entry} = reader("he", "Kenji")
      {:ok, entry} = entry |> Ecto.Changeset.change(language: "en") |> TravelingPoet.Repo.update()

      message =
        TravelingPoet.Email.EntryEmail.build(%{
          user: user,
          poet: poet,
          entry: entry,
          day: 1,
          page_url: "https://poet.travel/journal/2026-10-12",
          unsubscribe_url: "https://poet.travel/email/unsubscribe/x",
          listen?: true,
          listen_minutes: 4
        })

      assert message.html =~ ~s(<p lang="en" dir="ltr"><b>Fado</b></p>)
      assert message.html =~ ~s(<p lang="en" dir="ltr">Twelve strings, one ache.</p>)
      assert message.html =~ "או להאזין, בערך 4 דקות"
    end

    test "is today's English for an English reader" do
      %{poet: poet, entry: entry} = reader("en", "Kenji")
      EmailNotifier.send_entry(poet.id, entry.id)

      assert_receive {:resend, sent}
      assert sent["html"] =~ ~s(<html lang="en" dir="ltr">)
      assert sent["html"] =~ "Kenji in Lisbon"
      assert sent["html"] =~ "Read today's page"
      assert sent["html"] =~ "A new page from Kenji each day."
      assert sent["text"] =~ "Stop these emails: "
    end
  end

  describe "Telegram" do
    test "the reader's notes are in Hebrew for a Hebrew reader" do
      %{user: user, poet: poet, entry: entry} = reader("he", "Nam")

      Locale.with_locale(user.locale, fn ->
        assert Notifier.publish_text(poet, entry, 3, "L") ==
                 "יום 3 · Nam: Twelve strings, one ache.\nL"

        assert Notifier.publish_text(poet, %{entry | teaser: nil, title: nil}, 3, "L") =~
                 "עמוד חדש מ-Lisbon"

        assert Notifier.credits_low_text(poet, 0, "L") =~ "נגמרו הקרדיטים של Nam"
        assert Notifier.book_ready_text(poet, "L") == "הספר שלכם עם Nam מוכן.\nL"
        assert Notifier.question_text(poet, %{question: "?"}) =~ "אפשר פשוט לענות כאן."
      end)
    end

    test "the bot answers a Hebrew reader in Hebrew" do
      Locale.with_locale("he", fn ->
        assert Poller.paired_text(%{name: "Nam"}) =~ "החיבור הצליח!"
        assert Poller.reply(:packing) == "המשורר שלכם עוד באמצע האריזות. הציצו באפליקציה."
        refute Poller.reply(:not_paired) =~ "paired"
      end)
    end

    test "English readers get today's words" do
      %{user: user, poet: poet, entry: entry} = reader("en", "Nam")

      Locale.with_locale(user.locale, fn ->
        assert Notifier.publish_text(poet, entry, 3, "L") ==
                 "Day 3 · Nam: Twelve strings, one ache.\nL"

        assert Notifier.credits_low_text(poet, 0, "L") ==
                 "💤 Nam has run out of credits and is resting. Top up: L"

        assert Poller.reply(:packing) == "Your poet is still packing — check the app."
      end)
    end
  end
end
