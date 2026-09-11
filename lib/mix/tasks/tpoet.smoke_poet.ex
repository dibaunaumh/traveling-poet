defmodule Mix.Tasks.Tpoet.SmokePoet do
  @shortdoc "Provisions a throwaway test poet end-to-end and chats with it"

  @moduledoc """
  End-to-end smoke test for the riskiest integrations: sprite provisioning,
  OpenClaw install, gateway Ed25519 handshake, OpenRouter model config, and a
  real agent turn.

      mix tpoet.smoke_poet             # provision (idempotent) + chat round-trip
      mix tpoet.smoke_poet --teardown  # delete the smoke sprite + user

  Requires SPRITES_TOKEN and OPENROUTER_API_KEY in .env.
  """

  use Mix.Task

  alias TravelingPoet.{
    Accounts,
    GatewaySocket,
    GatewaySocketSupervisor,
    Poets,
    Provisioner,
    Repo,
    SpriteHold
  }

  alias TravelingPoet.Accounts.User

  @smoke_email "smoke-poet@example.com"
  @reply_timeout_ms 180_000

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    if "--teardown" in args do
      teardown()
    else
      run_smoke()
    end
  end

  defp run_smoke do
    case Provisioner.missing_prerequisites() do
      [] ->
        :ok

      missing ->
        Mix.raise(
          "Missing required env vars in .env: #{Enum.join(missing, ", ")}. " <>
            "The gateway cannot start without them (see .env.example)."
        )
    end

    user = ensure_user()
    poet = ensure_poet(user)
    IO.puts("== Smoke poet: user #{user.id}, poet #{poet.id} (#{poet.name})")

    IO.puts("== Provisioning (idempotent)...")
    t0 = System.monotonic_time(:millisecond)

    case Provisioner.provision_user(user) do
      {:ok, result} ->
        IO.puts("== Provisioned #{result.sprite_name} at #{result.sprite_url} (#{elapsed(t0)}s)")

      {:error, reason} ->
        Mix.raise("Provisioning failed: #{inspect(reason)}")
    end

    user = Accounts.get_user!(user.id)

    IO.puts("== Connecting gateway (Ed25519 handshake)...")
    t1 = System.monotonic_time(:millisecond)

    {:ok, pid} =
      case GatewaySocketSupervisor.ensure_connected(user, attempts: 10) do
        {:ok, pid} -> {:ok, pid}
        {:error, reason} -> Mix.raise("Gateway connect failed: #{inspect(reason)}")
      end

    GatewaySocket.subscribe(pid)

    check_sprite_hold(user.sprite_name)

    IO.puts("== Sending hello...")
    GatewaySocket.send_message(pid, "Hello! Reply with one short sentence about where you are.")

    case collect_reply("", t1) do
      {:ok, reply} ->
        IO.puts("== Agent replied (#{elapsed(t1)}s):\n#{String.slice(reply, 0, 500)}")
        IO.puts("\nSMOKE TEST PASSED")

      {:error, reason} ->
        Mix.raise("No agent reply: #{inspect(reason)}")
    end
  end

  # Round-trips the Sprites Tasks API through exec: the hold every turn relies
  # on, and proof that `curl` and the management socket exist in the image.
  defp check_sprite_hold(sprite_name) do
    IO.puts("== Sprite hold: put/list/delete tpoet-smoke task...")
    task = "tpoet-smoke"

    :ok = SpriteHold.put(sprite_name, task, "2m")

    case SpriteHold.list(sprite_name) do
      {:ok, listed} ->
        names = task_names(listed)

        unless task in names do
          Mix.raise("Sprite hold: task #{task} not listed after put: #{inspect(listed)}")
        end

      other ->
        Mix.raise("Sprite hold: list failed: #{inspect(other)}")
    end

    :ok = SpriteHold.delete(sprite_name, task)

    case SpriteHold.list(sprite_name) do
      {:ok, listed} ->
        if task in task_names(listed) do
          Mix.raise("Sprite hold: task #{task} still listed after delete: #{inspect(listed)}")
        end

      other ->
        Mix.raise("Sprite hold: list after delete failed: #{inspect(other)}")
    end

    IO.puts("== Sprite hold OK")
  end

  defp task_names(%{"tasks" => tasks}) when is_list(tasks), do: task_names(tasks)
  defp task_names(tasks) when is_list(tasks), do: Enum.map(tasks, & &1["name"])
  defp task_names(_), do: []

  defp collect_reply(acc, t_start) do
    receive do
      {:gateway_event, {:text_delta, delta}} ->
        collect_reply(acc <> delta, t_start)

      {:gateway_event, {:text_replace, text}} ->
        collect_reply(text, t_start)

      {:gateway_event, {:done, _}} when acc != "" ->
        {:ok, acc}

      {:gateway_event, {:done, _}} ->
        collect_reply(acc, t_start)

      {:gateway_event, {:error, reason}} ->
        {:error, reason}

      _other ->
        collect_reply(acc, t_start)
    after
      @reply_timeout_ms -> {:error, :timeout}
    end
  end

  defp ensure_user do
    case Repo.get_by(User, email: @smoke_email) do
      nil ->
        {:ok, user} =
          %User{}
          |> User.changeset(%{
            email: @smoke_email,
            name: "Smoke Tester",
            google_id: "smoke-test-google-id",
            quota_exempt: true
          })
          |> Repo.insert()

        user

      user ->
        user
    end
  end

  defp ensure_poet(user) do
    case Poets.get_poet_by_user(user.id) do
      nil ->
        {:ok, poet} =
          Poets.create_poet(%{
            user_id: user.id,
            name: "Basho the Smoke Poet",
            personality: "calm, minimal, observant",
            interests: ["haiku", "rivers", "old roads"],
            currently_reading: %{
              "items" => [
                %{"title" => "The Narrow Road to the Deep North", "author" => "Matsuo Basho"}
              ]
            },
            current_lat: 35.0116,
            current_lng: 135.7681,
            current_place_name: "Kyoto, Japan",
            current_country_code: "JP",
            arrived_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })

        poet

      poet ->
        poet
    end
  end

  defp teardown do
    case Repo.get_by(User, email: @smoke_email) do
      nil ->
        IO.puts("No smoke user found.")

      user ->
        IO.puts("Deleting sprite + smoke user #{user.id}...")
        Provisioner.deprovision_user(user)
        Repo.delete!(user)
        IO.puts("Done.")
    end
  end

  defp elapsed(t0), do: Float.round((System.monotonic_time(:millisecond) - t0) / 1000, 1)
end
