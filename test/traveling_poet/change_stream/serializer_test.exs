defmodule TravelingPoet.ChangeStream.SerializerTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.ChangeStream.Serializer
  alias TravelingPoet.{Accounts, Chat, Poets}

  test "users lose every secret and identity field, keep the rest" do
    user = agent_user_fixture(%{telegram_chat_id: 12345, telegram_username: "udi"})

    {:ok, user} =
      Accounts.update_user(user, %{
        gateway_token: "gw-secret",
        telegram_pair_token: "pair-secret",
        device_public_key: <<1, 2, 3>>,
        device_private_key: <<4, 5, 6>>
      })

    record = Serializer.encode("users", user)

    for gone <-
          ~w(email google_id apple_id telegram_chat_id telegram_username gateway_token
             agent_api_token telegram_pair_token device_public_key device_private_key) do
      refute Map.has_key?(record, gone), "#{gone} leaked"
    end

    assert record["id"] == user.id
    assert record["name"] == user.name
    assert record["is_admin"] == false
    assert record["credits_balance"] == 0
    assert is_binary(record["inserted_at"])
    refute Map.has_key?(record, "__meta__")
    refute Map.has_key?(record, "poet")
  end

  test "chat messages drop the content, keep the envelope" do
    user = user_fixture()
    {:ok, msg} = Chat.create_message(%{user_id: user.id, role: "user", content: "private"})

    record = Serializer.encode("chat_messages", msg)
    refute Map.has_key?(record, "content")
    assert record["role"] == "user"
    assert record["channel"] == "web"
    assert record["user_id"] == user.id
  end

  test "places go through intact, including address and coordinates" do
    user = user_fixture()
    poet = poet_fixture(user)
    entry = entry_fixture(poet)
    place = place_fixture(poet, entry, %{address: "Rua Garrett 120", lat: 38.71, lng: -9.14})

    record = Serializer.encode("places", place)
    assert record["address"] == "Rua Garrett 120"
    assert record["lat"] == 38.71
    assert record["entry_date"] == Date.to_iso8601(entry.entry_date)
    assert record["name"] == place.name
  end

  test "media loses its bucket key" do
    user = user_fixture()
    poet = poet_fixture(user)
    media = media_fixture(poet)

    record = Serializer.encode("media", media)
    refute Map.has_key?(record, "s3_key")
    assert record["content_type"] == "image/png"
    assert record["sources"]["items"] |> hd() |> Map.fetch!("url") =~ "example.com"
  end

  test "nested free-form maps are scanned with the same patterns" do
    user = user_fixture()

    poet =
      poet_fixture(user, %{
        settings: %{
          "mode" => "wander",
          "api_token" => "leak",
          "contact" => %{"email" => "x@y.z", "note" => "ok"}
        }
      })

    record = Serializer.encode("poets", poet)
    assert record["settings"]["mode"] == "wander"
    refute Map.has_key?(record["settings"], "api_token")
    refute Map.has_key?(record["settings"]["contact"], "email")
    assert record["settings"]["contact"]["note"] == "ok"
  end

  test "preference `key` is not mistaken for a credential" do
    refute Serializer.redacted_field?("poet_preferences", "key")
    assert Serializer.redacted_field?("media", "s3_key")
    assert Serializer.redacted_field?("users", "email")
    refute Serializer.redacted_field?("poets", "name")
    assert Serializer.redacted_field?("anything", :agent_api_token)
  end

  test "fingerprint is stable and changes with content" do
    user = user_fixture()
    poet = poet_fixture(user, %{name: "Nam"})

    fp1 = Serializer.fingerprint(Serializer.encode("poets", poet))
    fp2 = Serializer.fingerprint(Serializer.encode("poets", poet))
    assert fp1 == fp2
    assert String.length(fp1) == 64

    {:ok, renamed} = Poets.update_poet(poet, %{name: "Nam II"})
    refute Serializer.fingerprint(Serializer.encode("poets", renamed)) == fp1
  end
end
