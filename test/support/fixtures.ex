defmodule TravelingPoet.Fixtures do
  @moduledoc "Test data helpers."

  alias TravelingPoet.{Accounts, Poets, Repo}
  alias TravelingPoet.Accounts.User

  @doc "Pass `credits: n` to seed a balance (whole credits) via the ledger."
  def user_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {credits, attrs} = Map.pop(attrs, :credits)

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

    if credits do
      {:ok, _} = TravelingPoet.Credits.adjust(user, credits)
      Accounts.get_user!(user.id)
    else
      user
    end
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

  def entry_fixture(poet, attrs \\ %{}) do
    {:ok, entry} =
      TravelingPoet.Journal.upsert_entry(
        poet.id,
        Map.get(attrs, :entry_date, Date.utc_today()),
        Map.merge(
          %{place_name: "Lisbon, Portugal", title: "A day"},
          Map.delete(attrs, :entry_date)
        )
      )

    entry
  end

  def published_entry_fixture(poet, attrs \\ %{}) do
    {:ok, entry} = TravelingPoet.Journal.publish_entry(entry_fixture(poet, attrs))
    entry
  end

  def place_fixture(poet, entry, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, place} =
      %TravelingPoet.Guide.Place{}
      |> TravelingPoet.Guide.Place.changeset(
        Map.merge(
          %{
            poet_id: poet.id,
            journal_entry_id: entry.id,
            entry_date: entry.entry_date,
            name: "Place #{n}",
            category: "restaurant",
            position: 0
          },
          attrs
        )
      )
      |> Repo.insert()

    place
  end

  def media_fixture(poet, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, media} =
      %TravelingPoet.Journal.Media{}
      |> TravelingPoet.Journal.Media.changeset(
        Map.merge(
          %{
            poet_id: poet.id,
            s3_key: "media/test-#{n}.png",
            content_type: "image/png",
            kind: "illustration",
            sources: %{"items" => [%{"url" => "https://example.com/#{n}", "label" => "ref"}]}
          },
          attrs
        )
      )
      |> Repo.insert()

    media
  end
end
