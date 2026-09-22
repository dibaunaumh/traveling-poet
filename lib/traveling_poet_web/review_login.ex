defmodule TravelingPoetWeb.ReviewLogin do
  @moduledoc """
  A password sign-in for App Store review, into one demo account.

  Every real way in goes through Google or Apple. An App Store reviewer has
  neither of ours, and a brand-new account of their own shows an empty
  journal for the minutes a first entry takes to write, which reads as an
  unfinished app. So there is one seeded account with weeks of entries, and
  this is the door to it.

  It does not exist unless BOTH secrets are set: `REVIEW_LOGIN_EMAIL`, the
  demo account's address (it must already exist), and
  `REVIEW_LOGIN_PASSWORD_HASH`, from `hash_password/1`. Unset either and the
  routes answer 404, which is how it is switched off after approval:

      fly secrets unset REVIEW_LOGIN_PASSWORD_HASH -c fly.dev.toml

  To make a hash (release: `rpc`, not `eval`):

      TravelingPoetWeb.ReviewLogin.hash_password("the password for the review notes")

  It can only ever open that one account, the password is checked in constant
  time against a salted PBKDF2 hash, and failed attempts are capped for the
  whole app (one machine, one counter), so it cannot be ground down.
  """

  alias TravelingPoet.Accounts

  @iterations 210_000
  @max_failures 8
  @window_seconds 15 * 60
  @counter {__MODULE__, :failures}

  def enabled?, do: email() not in [nil, ""] and password_hash() not in [nil, ""]

  defp email, do: Application.get_env(:traveling_poet, :review_login_email)
  defp password_hash, do: Application.get_env(:traveling_poet, :review_login_password_hash)

  @doc "`pbkdf2-sha256$<iterations>$<salt>$<hash>`, to store as REVIEW_LOGIN_PASSWORD_HASH."
  def hash_password(password) when is_binary(password) and byte_size(password) >= 12 do
    salt = :crypto.strong_rand_bytes(16)
    "pbkdf2-sha256$#{@iterations}$#{b64(salt)}$#{b64(derive(password, salt, @iterations))}"
  end

  @doc """
  The demo account, when `email` and `password` are its credentials.
  `{:error, :throttled}` once too many attempts have failed recently.
  """
  def authenticate(typed_email, password) when is_binary(typed_email) and is_binary(password) do
    cond do
      not enabled?() ->
        {:error, :disabled}

      throttled?() ->
        {:error, :throttled}

      true ->
        # Both checks always run, so the answer takes as long either way.
        email_ok? =
          Plug.Crypto.secure_compare(
            String.downcase(String.trim(typed_email)),
            String.downcase(email())
          )

        password_ok? = valid_password?(password, password_hash())

        with true <- email_ok? and password_ok?,
             %{} = user <- Accounts.get_user_by_email(email()) do
          {:ok, user}
        else
          _ ->
            note_failure()
            {:error, :invalid}
        end
    end
  end

  def authenticate(_, _), do: {:error, :invalid}

  defp valid_password?(password, "pbkdf2-sha256$" <> rest) do
    with [iterations, salt, hash] <- String.split(rest, "$"),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.url_decode64(salt, padding: false),
         {:ok, hash} <- Base.url_decode64(hash, padding: false) do
      Plug.Crypto.secure_compare(derive(password, salt, iterations), hash)
    else
      _ -> false
    end
  end

  defp valid_password?(_password, _hash), do: false

  defp derive(password, salt, iterations),
    do: :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  # One counter for the whole app. A lost update between two racing requests
  # undercounts by one, which does not matter here.
  defp throttled? do
    case :persistent_term.get(@counter, nil) do
      {started, count} -> now() - started < @window_seconds and count >= @max_failures
      nil -> false
    end
  end

  defp note_failure do
    case :persistent_term.get(@counter, nil) do
      {started, count} when is_integer(started) ->
        if now() - started < @window_seconds,
          do: :persistent_term.put(@counter, {started, count + 1}),
          else: :persistent_term.put(@counter, {now(), 1})

      nil ->
        :persistent_term.put(@counter, {now(), 1})
    end
  end

  @doc false
  def reset_throttle, do: :persistent_term.erase(@counter)

  defp now, do: System.os_time(:second)
end
