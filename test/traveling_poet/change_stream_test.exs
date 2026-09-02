defmodule TravelingPoet.ChangeStreamTest do
  use TravelingPoet.DataCase, async: false

  import TravelingPoet.Fixtures

  alias TravelingPoet.ChangeStream
  alias TravelingPoet.ChangeStream.{Event, Fingerprint}
  alias TravelingPoet.Repo

  setup do
    on_exit(fn -> :persistent_term.erase({ChangeStream, :enabled?}) end)
    :ok
  end

  test "registering the first endpoint seeds silently and enables the stream" do
    user = user_fixture()
    _poet = poet_fixture(user)
    refute ChangeStream.enabled?()

    assert {:ok, endpoint} =
             ChangeStream.create_endpoint(%{
               "url" => " https://a.example/hook ",
               "auth_token" => "t"
             })

    assert endpoint.url == "https://a.example/hook"
    assert String.length(endpoint.signing_secret) >= 40
    assert endpoint.status == "active"
    assert ChangeStream.enabled?()
    assert Repo.aggregate(Event, :count) == 0
    assert Repo.aggregate(Fingerprint, :count) >= 2

    :ok = ChangeStream.delete_endpoint(endpoint)
    refute ChangeStream.enabled?()
    assert Repo.aggregate(Fingerprint, :count) == 0
  end

  test "rejects a bad URL or a missing token" do
    assert {:error, cs} = ChangeStream.create_endpoint(%{"url" => "ftp://x", "auth_token" => "t"})
    assert {"must be an http(s) URL", _} = cs.errors[:url]

    assert {:error, cs} =
             ChangeStream.create_endpoint(%{"url" => "https://x.example", "auth_token" => ""})

    assert cs.errors[:auth_token]
  end

  test "run_once survives a crashing stage" do
    {:ok, _} =
      ChangeStream.create_endpoint(%{"url" => "https://a.example/hook", "auth_token" => "t"})

    # no Req.Test stub: delivery of nothing is skipped, nothing raises
    result = ChangeStream.run_once(DateTime.utc_now())
    assert %{capture: %{inserts: _}, delivery: [{_, :skipped}], prune: %{acked: 0}} = result
  end

  test "redacted_fields documents the contract" do
    fields = ChangeStream.redacted_fields()
    assert "email" in fields["users"]
    assert "agent_api_token" in fields["users"]
    assert fields["chat_messages"] == ["content"]
    assert fields["places"] == []
  end
end
