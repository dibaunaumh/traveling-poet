defmodule TravelingPoet.Accounts do
  @moduledoc """
  The Accounts context for managing users.
  """

  import Ecto.Query, warn: false
  alias TravelingPoet.Repo
  alias TravelingPoet.Accounts.User
  require Logger

  @doc """
  Finds or creates a user from a sign-in, by provider (`:google`, `:apple`).

  One person, one account, however they sign in: `users.email` is unique, so
  someone who made their poet with Google on the web and then signs in with
  Apple in the app (same address) must arrive at that poet, not at an error.
  An identity new to us is therefore attached to the account that already
  holds its email, but ONLY when the provider vouches that the email is
  verified (`"email_verified" => true`), since an unverified address is
  anyone's to type. Apple's "Hide My Email" relay addresses are unique to
  each app and never match anything; they get an account of their own.

  `"name"` may be missing: Apple sends it once, on the very first sign-in.
  """
  def find_or_create_from_oauth(:google, %{"sub" => sub} = info),
    do: find_or_create(:google_id, sub, info)

  def find_or_create_from_oauth(:apple, %{"sub" => sub} = info),
    do: find_or_create(:apple_id, sub, info)

  defp find_or_create(identity, sub, info) when is_binary(sub) and sub != "" do
    email = info["email"]
    name = info["name"]

    cond do
      user = Repo.get_by(User, [{identity, sub}]) ->
        fill_in_name(user, name)

      email in [nil, ""] ->
        {:error, :no_email}

      user = info["email_verified"] == true && get_user_by_email(email) ->
        with {:ok, user} <- user |> User.changeset(%{identity => sub}) |> Repo.update() do
          Logger.info("Accounts: linked #{identity} to user #{user.id} by verified email")
          fill_in_name(user, name)
        end

      true ->
        with {:ok, user} <-
               %User{}
               |> User.changeset(%{identity => sub, email: email, name: name})
               |> Repo.insert() do
          # Welcome credits; idempotent on "signup:<id>" so a retry can't double-grant.
          {:ok, _} = TravelingPoet.Credits.grant_signup(user)
          {:ok, Repo.get!(User, user.id)}
        end
    end
  end

  defp find_or_create(_identity, _sub, _info), do: {:error, :no_subject}

  defp fill_in_name(user, name) when name in [nil, ""], do: {:ok, user}

  defp fill_in_name(user, name) do
    if user.name in [nil, ""],
      do: user |> User.changeset(%{name: name}) |> Repo.update(),
      else: {:ok, user}
  end

  def get_user_by_email(email) when is_binary(email) and email != "" do
    Repo.one(from u in User, where: fragment("lower(?)", u.email) == ^String.downcase(email))
  end

  def get_user_by_email(_), do: nil

  def get_user_by_apple_id(apple_id) when is_binary(apple_id),
    do: Repo.get_by(User, apple_id: apple_id)

  def get_user_by_apple_id(_), do: nil

  def get_user_by_google_id(google_id) when is_binary(google_id),
    do: Repo.get_by(User, google_id: google_id)

  def get_user_by_google_id(_), do: nil

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
