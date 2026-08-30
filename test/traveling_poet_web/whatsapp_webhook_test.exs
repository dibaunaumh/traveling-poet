defmodule TravelingPoetWeb.WhatsAppWebhookTest do
  use TravelingPoetWeb.ConnCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.Messaging

  @app_secret "wa_app_secret"
  @verify_token "wa_verify"

  setup do
    Application.put_env(:traveling_poet, :whatsapp_app_secret, @app_secret)
    Application.put_env(:traveling_poet, :whatsapp_verify_token, @verify_token)
    Application.put_env(:traveling_poet, :whatsapp_phone_number_id, "123456")
    Application.put_env(:traveling_poet, :whatsapp_business_number, "15550123456")
    # No access token: the adapter refuses to send, so nothing here can reach
    # Meta even if a code path tries.
    Application.put_env(:traveling_poet, :whatsapp_access_token, nil)

    on_exit(fn ->
      for key <- [
            :whatsapp_app_secret,
            :whatsapp_verify_token,
            :whatsapp_phone_number_id,
            :whatsapp_business_number,
            :whatsapp_access_token
          ],
          do: Application.delete_env(:traveling_poet, key)
    end)

    :ok
  end

  defp sign(body, secret \\ @app_secret) do
    "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
  end

  defp post_signed(body, signature) do
    build_conn()
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-hub-signature-256", signature)
    |> post(~p"/webhooks/whatsapp", body)
  end

  defp text_event(from, text, id) do
    Jason.encode!(%{
      "object" => "whatsapp_business_account",
      "entry" => [
        %{
          "id" => "waba-1",
          "changes" => [
            %{
              "field" => "messages",
              "value" => %{
                "messaging_product" => "whatsapp",
                "contacts" => [%{"wa_id" => from, "profile" => %{"name" => "Beta Tester"}}],
                "messages" => [
                  %{
                    "from" => from,
                    "id" => id,
                    "timestamp" => "1756400000",
                    "type" => "text",
                    "text" => %{"body" => text}
                  }
                ]
              }
            }
          ]
        }
      ]
    })
  end

  describe "GET (subscription handshake)" do
    test "echoes the challenge when the verify token matches" do
      conn =
        get(
          build_conn(),
          ~p"/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=#{@verify_token}&hub.challenge=chal-123"
        )

      assert response(conn, 200) == "chal-123"
    end

    test "rejects a wrong verify token" do
      conn =
        get(
          build_conn(),
          ~p"/webhooks/whatsapp?hub.mode=subscribe&hub.verify_token=nope&hub.challenge=chal-123"
        )

      assert response(conn, 403) == ""
    end
  end

  describe "POST (inbound messages)" do
    test "an unsigned or wrongly signed payload is rejected" do
      body = text_event("15559998888", "hello", "wamid.1")

      assert json_response(post_signed(body, sign(body, "wrong-secret")), 400)
      assert json_response(post_signed(body, "sha256=deadbeef"), 400)
    end

    test "a signed PAIR message pairs the conversation" do
      user = user_fixture()
      {:ok, link} = Messaging.mint_pair_link(user, "whatsapp")

      token =
        link |> String.split("text=") |> List.last() |> URI.decode_www_form()

      body = text_event("15559998888", token, "wamid.pair")
      assert json_response(post_signed(body, sign(body)), 200) == %{"received" => true}

      # The controller works off the request; give the task a moment to land.
      assert eventually(fn -> Messaging.paired?(user, "whatsapp") end)

      channel = Messaging.get_channel(user.id, "whatsapp")
      assert channel.external_id == "15559998888"
      assert channel.username == "Beta Tester"
    end

    test "a redelivered message is only handled once" do
      user = user_fixture()
      {:ok, link} = Messaging.mint_pair_link(user, "whatsapp")
      token = link |> String.split("text=") |> List.last() |> URI.decode_www_form()

      body = text_event("15557654321", token, "wamid.dup")
      assert json_response(post_signed(body, sign(body)), 200)
      assert eventually(fn -> Messaging.paired?(user, "whatsapp") end)

      # Meta retries the same id: the token is spent, and the dedupe guard
      # means we don't even try (which would send an "expired link" reply).
      assert json_response(post_signed(body, sign(body)), 200)
      assert Messaging.paired?(user, "whatsapp")
    end

    test "statuses and other non-message events are accepted and ignored" do
      body =
        Jason.encode!(%{
          "object" => "whatsapp_business_account",
          "entry" => [
            %{
              "changes" => [
                %{
                  "field" => "messages",
                  "value" => %{"statuses" => [%{"id" => "wamid.x", "status" => "delivered"}]}
                }
              ]
            }
          ]
        })

      assert json_response(post_signed(body, sign(body)), 200) == %{"received" => true}
    end
  end

  # The webhook hands off to a Task, so pairing lands just after the response.
  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts <= 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
