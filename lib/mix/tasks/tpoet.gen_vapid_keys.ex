defmodule Mix.Tasks.Tpoet.GenVapidKeys do
  @shortdoc "Prints a fresh VAPID key pair for Web Push (set as env/Fly secrets)"

  @moduledoc """
  Generates the application-server key pair browsers use to trust our pushes.

      mix tpoet.gen_vapid_keys

  Put the two values in `.env` (dev) or `fly secrets set` (prod). Rotating
  them invalidates every existing subscription, so generate once and keep.
  """

  use Mix.Task

  @impl true
  def run(_args) do
    %{public_key: pub, private_key: priv} = TravelingPoet.WebPush.Crypto.generate_vapid_keys()

    Mix.shell().info("""
    VAPID_PUBLIC_KEY=#{pub}
    VAPID_PRIVATE_KEY=#{priv}
    """)
  end
end
