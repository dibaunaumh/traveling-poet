defmodule TravelingPoet.Fixtures do
  @moduledoc "Test data helpers."

  alias TravelingPoet.{Accounts, Poets, Repo}
  alias TravelingPoet.Accounts.User

  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      %User{}
      |> User.changeset(
        Map.merge(
          %{
            email: "user#{n}@example.com",
            name: "Test User #{n}",
            google_id: "google-#{n}"
          },
          attrs
        )
      )
      |> Repo.insert()

    user
  end

  def agent_user_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)
    token = "#{user.id}." <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    {:ok, user} = Accounts.update_user(user, %{agent_api_token: token, sprite_provisioned: true})
    user
  end

  def poet_fixture(user, attrs \\ %{}) do
    {:ok, poet} =
      Poets.create_poet(
        Map.merge(
          %{
            user_id: user.id,
            name: "Poet #{System.unique_integer([:positive])}",
            personality: "curious",
            current_lat: 38.7223,
            current_lng: -9.1393,
            current_place_name: "Lisbon, Portugal",
            current_country_code: "PT",
            arrived_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )

    poet
  end
end
