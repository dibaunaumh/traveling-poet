defmodule TravelingPoet.Accounts.Purge do
  @moduledoc """
  Deletes a user and everything that belongs to them — for testing the sign-up
  flow end to end, where a half-removed account is worse than none at all
  (a stale `google_id` row would just log you back into the old account
  instead of running onboarding).

  Three layers come off, in this order:

    1. **Media in object storage.** Deleted first, while the rows that name
       the keys still exist. Failures here are logged, not fatal — an orphaned
       image costs pennies, a half-deleted database costs an afternoon.
    2. **The sprite sandbox.** Also best-effort: the sandbox may already be
       gone, and sprites.dev being down shouldn't block the purge.
    3. **The user row.** Every table hangs off `users` with
       `on_delete: :delete_all` (foreign keys are enforced — `PRAGMA
       foreign_keys` is on), so one delete takes the poet, journal entries,
       sections, media rows, reactions, path points, itinerary stops, chat
       messages, messaging channels, usage events and the credit ledger.

  This is irreversible and leaves nothing to restore from. `purge/2` requires
  the caller to pass the account's own email as confirmation, so an id typo
  can't take the wrong account with it.
  """

  require Logger

  import Ecto.Query

  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Journal.Media
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.{Repo, SpritesClient, Storage}

  @doc """
  Purges the user with `id`, but only when `confirm_email` matches the address
  on that account — the guard against purging by mistyped id.

  Returns `{:ok, summary}` or `{:error, reason}`, where summary counts what
  went with it.
  """
  def purge(id, confirm_email) when is_binary(confirm_email) do
    case Repo.get(User, id) do
      nil ->
        {:error, :not_found}

      user ->
        if String.downcase(String.trim(confirm_email)) == String.downcase(user.email) do
          do_purge(user)
        else
          {:error, :email_mismatch}
        end
    end
  end

  @doc "Purges by email address — the form a script or console reaches for."
  def purge_by_email(email) when is_binary(email) do
    case Repo.get_by(User, email: String.downcase(String.trim(email))) do
      nil -> {:error, :not_found}
      user -> do_purge(user)
    end
  end

  defp do_purge(%User{} = user) do
    poet = Repo.get_by(Poet, user_id: user.id)
    media_keys = media_keys(poet)

    Logger.warning(
      "Purge: deleting user #{user.id} (#{user.email}), poet #{inspect(poet && poet.name)}, " <>
        "#{length(media_keys)} media object(s), sprite #{inspect(user.sprite_name)}"
    )

    media_deleted = delete_media(media_keys)
    sprite_deleted = delete_sprite(user.sprite_name)

    case Repo.delete(user) do
      {:ok, _} ->
        {:ok,
         %{
           user_id: user.id,
           email: user.email,
           poet: poet && poet.name,
           media_deleted: media_deleted,
           media_total: length(media_keys),
           sprite: sprite_deleted
         }}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp media_keys(nil), do: []

  defp media_keys(poet) do
    Media
    |> where(poet_id: ^poet.id)
    |> where([m], not is_nil(m.s3_key))
    |> select([m], m.s3_key)
    |> Repo.all()
  end

  defp delete_media([]), do: 0

  defp delete_media(keys) do
    if storage_configured?() do
      Enum.count(keys, fn key ->
        case Storage.S3.delete_file(key) do
          :ok ->
            true

          {:ok, _} ->
            true

          other ->
            Logger.warning("Purge: could not delete media #{key}: #{inspect(other)}")
            false
        end
      end)
    else
      0
    end
  end

  defp delete_sprite(nil), do: :none

  defp delete_sprite(name) do
    if sprites_configured?() do
      case SpritesClient.delete_sprite(name) do
        {:ok, _} ->
          :deleted

        other ->
          Logger.warning("Purge: could not delete sprite #{name}: #{inspect(other)}")
          :failed
      end
    else
      :not_configured
    end
  end

  # Neither cleanup is worth a network call in test or a bare dev box, and
  # attempting one there just times out mid-purge.
  defp sprites_configured?,
    do: Application.get_env(:traveling_poet, :sprites_token) not in [nil, ""]

  defp storage_configured?, do: System.get_env("AWS_ACCESS_KEY_ID") not in [nil, ""]
end
