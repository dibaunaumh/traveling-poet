defmodule Mix.Tasks.Tpoet.DeleteUser do
  @shortdoc "Deletes a user account and everything attached to it"

  @moduledoc """
  Removes a user so the sign-up flow can be tested from scratch — the account,
  its poet, journal, media, chat, ledger, and the sprite sandbox.

      mix tpoet.delete_user someone@example.com
      mix tpoet.delete_user someone@example.com --yes   # skip the prompt

  Irreversible, and there is no backup to restore from. Without `--yes` it
  prints what will go and waits for you to type the email back.

  On prod this task isn't available (releases don't ship Mix). Use:

      fly ssh console -c fly.dev.toml -C \\
        "/app/bin/traveling_poet rpc \\
         'TravelingPoet.Accounts.Purge.purge_by_email(\\"someone@example.com\\")'"
  """

  use Mix.Task

  alias TravelingPoet.Accounts.Purge
  alias TravelingPoet.Accounts.User
  alias TravelingPoet.Poets.Poet
  alias TravelingPoet.Repo

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [yes: :boolean])

    case positional do
      [email] -> delete(email, opts[:yes] == true)
      _ -> Mix.raise("Usage: mix tpoet.delete_user EMAIL [--yes]")
    end
  end

  defp delete(email, skip_prompt?) do
    Mix.Task.run("app.start")
    email = email |> String.trim() |> String.downcase()

    case Repo.get_by(User, email: email) do
      nil ->
        Mix.shell().error("No user with email #{email}")
        exit({:shutdown, 1})

      user ->
        describe(user)

        if skip_prompt? or confirmed?(email) do
          case Purge.purge_by_email(email) do
            {:ok, summary} ->
              Mix.shell().info("""

              Deleted user #{summary.user_id} (#{summary.email})
                poet:   #{summary.poet || "none"}
                media:  #{summary.media_deleted}/#{summary.media_total} objects removed
                sprite: #{summary.sprite}

              Sign up again with this address to run onboarding from scratch.
              """)

            {:error, reason} ->
              Mix.shell().error("Purge failed: #{inspect(reason)}")
              exit({:shutdown, 1})
          end
        else
          Mix.shell().info("Left alone.")
        end
    end
  end

  defp describe(user) do
    poet = Repo.get_by(Poet, user_id: user.id)

    Mix.shell().info("""
    About to permanently delete:
      user   #{user.id} — #{user.email}
      poet   #{(poet && "#{poet.name} (#{poet.current_place_name || "nowhere"})") || "none"}
      sprite #{user.sprite_name || "none"}
      plus every journal entry, illustration, chat message, credit and usage row.
    """)
  end

  defp confirmed?(email) do
    Mix.shell().prompt("Type the email to confirm: ") |> String.trim() |> String.downcase() ==
      email
  end
end
