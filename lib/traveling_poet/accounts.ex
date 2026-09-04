defmodule TravelingPoet.Accounts do
  @moduledoc """
  The Accounts context for managing users.
  """

  import Ecto.Query, warn: false
  alias TravelingPoet.Repo
  alias TravelingPoet.Accounts.User
  require Logger

  @doc """
  Finds or creates a user from an OAuth callback.

  Dispatches on provider so "Sign in with Apple" can slot in later without
  touching callers — today only `:google` is wired.
  """
  def find_or_create_from_oauth(:google, %{"sub" => google_id, "email" => email, "name" => name}) do
    case Repo.get_by(User, google_id: google_id) do
      nil ->
        with {:ok, user} <-
               %User{}
               |> User.changeset(%{google_id: google_id, email: email, name: name})
               |> Repo.insert() do
          # Welcome credits; idempotent on "signup:<id>" so a retry can't double-grant.
          {:ok, _} = TravelingPoet.Credits.grant_signup(user)
          {:ok, Repo.get!(User, user.id)}
        end

      user ->
        if is_nil(user.name) or user.name == "" do
          user |> User.changeset(%{name: name}) |> Repo.update()
        else
          {:ok, user}
        end
    end
  end

  def get_user!(id), do: Repo.get!(User, id)
  def get_user(id), do: Repo.get(User, id)

  # Sessions are long-lived cookies, so the OAuth callback fires rarely and
  # says little about whether someone still opens the app. Instead every
  # authenticated page load stamps the user — debounced, since LiveView mounts
  # twice per visit and navigations remount.
  @seen_debounce_seconds 300

  @doc """
  Records that the user is looking at the app right now.

  Cheap no-op inside the debounce window; otherwise a single UPDATE with no
  changeset round-trip. Returns the user with `last_seen_at` refreshed.
  """
  def touch_last_seen(user, now \\ DateTime.utc_now())
  def touch_last_seen(nil, _now), do: nil

  def touch_last_seen(%User{} = user, now) do
    now = DateTime.truncate(now, :second)

    if recently_seen?(user, now) do
      user
    else
      from(u in User, where: u.id == ^user.id)
      |> Repo.update_all(set: [last_seen_at: now])

      %{user | last_seen_at: now}
    end
  end

  defp recently_seen?(%{last_seen_at: nil}, _now), do: false

  defp recently_seen?(%{last_seen_at: at}, now),
    do: DateTime.diff(now, at, :second) < @seen_debounce_seconds

  def get_user_by_agent_api_token(token) when is_binary(token) and token != "" do
    Repo.get_by(User, agent_api_token: token)
  end

  def get_user_by_agent_api_token(_), do: nil

  def get_user_by_telegram_chat_id(chat_id) when is_integer(chat_id) do
    Repo.get_by(User, telegram_chat_id: chat_id)
  end

  def get_user_by_telegram_pair_token(token) when is_binary(token) and token != "" do
    Repo.get_by(User, telegram_pair_token: token)
  end

  def get_user_by_telegram_pair_token(_), do: nil

  def update_user(user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Lists all users with provisioned sprites. When `version_filter` is provided,
  only returns users whose `openclaw_version` matches (or is nil — provisioned
  before version tracking).
  """
  def list_provisioned_users(version_filter \\ nil) do
    query = from(u in User, where: u.sprite_provisioned == true)

    query =
      if version_filter do
        from(u in query,
          where: u.openclaw_version == ^version_filter or is_nil(u.openclaw_version)
        )
      else
        query
      end

    Repo.all(query)
  end
end
