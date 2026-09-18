defmodule TravelingPoet.Geo do
  @moduledoc "Great-circle distance, shared by the route logic and trip detection."

  @earth_radius_km 6371

  @doc "Haversine distance in kilometres between two lat/lng points."
  def distance_km(lat1, lng1, lat2, lng2) do
    to_rad = &(&1 * :math.pi() / 180)
    dlat = to_rad.(lat2 - lat1)
    dlng = to_rad.(lng2 - lng1)

    a =
      :math.pow(:math.sin(dlat / 2), 2) +
        :math.cos(to_rad.(lat1)) * :math.cos(to_rad.(lat2)) * :math.pow(:math.sin(dlng / 2), 2)

    @earth_radius_km * 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end
end
