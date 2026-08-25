defmodule TravelingPoet.SpritesClient do
  @moduledoc """
  REST API client for the Sprites API (https://api.sprites.dev/v1/).
  """

  require Logger

  def create_sprite(name, opts \\ []) do
    body = Map.new(opts) |> Map.put(:name, name)

    req()
    |> Req.post(url: "/sprites", json: body)
    |> handle_response()
  end

  def update_sprite(name, url_settings) do
    req()
    |> Req.put(url: "/sprites/#{name}", json: %{url_settings: url_settings})
    |> handle_response()
  end

  def get_sprite(name) do
    req()
    |> Req.get(url: "/sprites/#{name}")
    |> handle_response()
  end

  def delete_sprite(name) do
    req()
    |> Req.delete(url: "/sprites/#{name}")
    |> handle_response()
  end

  def list_sprites do
    req()
    |> Req.get(url: "/sprites")
    |> handle_response()
  end

  def exec(name, command, _opts \\ []) do
    req()
    |> Req.post(
      url: "/sprites/#{name}/exec",
      params: %{cmd: "/bin/bash", stdin: true},
      body: command,
      receive_timeout: 120_000
    )
    |> handle_response()
  end

  def create_service(sprite_name, service_name, cmd, args \\ [], opts \\ []) do
    body = %{cmd: cmd, args: args} |> Map.merge(Map.new(opts))

    req()
    |> Req.put(url: "/sprites/#{sprite_name}/services/#{service_name}", json: body)
    |> handle_response()
  end

  def start_service(sprite_name, service_name) do
    req()
    |> Req.post(url: "/sprites/#{sprite_name}/services/#{service_name}/start")
    |> handle_response()
  end

  def stop_service(sprite_name, service_name) do
    req()
    |> Req.post(url: "/sprites/#{sprite_name}/services/#{service_name}/stop")
    |> handle_response()
  end

  def delete_service(sprite_name, service_name) do
    req()
    |> Req.delete(url: "/sprites/#{sprite_name}/services/#{service_name}")
    |> handle_response()
  end

  def get_service(sprite_name, service_name) do
    req()
    |> Req.get(url: "/sprites/#{sprite_name}/services/#{service_name}")
    |> handle_response()
  end

  def get_sprite_url(name) do
    case get_sprite(name) do
      {:ok, %{"url" => url}} -> {:ok, url}
      {:ok, data} -> {:error, {:no_url, data}}
      error -> error
    end
  end

  # -- internals --

  defp req do
    Req.new(
      base_url: api_url(),
      headers: [{"authorization", "Bearer #{token()}"}],
      receive_timeout: 60_000
    )
  end

  defp api_url do
    Application.get_env(:traveling_poet, :sprites_api_url, "https://api.sprites.dev/v1")
  end

  defp token do
    Application.get_env(:traveling_poet, :sprites_token, "")
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    Logger.debug("Sprites API #{status}: #{inspect(body, limit: 500)}")
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("Sprites API error #{status}: #{inspect(body, limit: 500)}")
    {:error, {status, body}}
  end

  defp handle_response({:error, reason} = error) do
    Logger.error("Sprites API request failed: #{inspect(reason)}")
    error
  end
end
