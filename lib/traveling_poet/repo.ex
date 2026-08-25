defmodule TravelingPoet.Repo do
  use Ecto.Repo,
    otp_app: :traveling_poet,
    adapter: Ecto.Adapters.SQLite3
end
