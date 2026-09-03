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
