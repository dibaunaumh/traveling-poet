defmodule TravelingPoet.Payments.AppleIAP do
  @moduledoc """
  Credits bought inside the iOS app, through Apple's In-App Purchase.

  Apple does not allow any other way to pay for credits in an app (App Store
  guideline 3.1.1); on the web it is Stripe (`Payments.Stripe`). This is not
  a `Payments` provider: that behaviour hands back a URL to redirect to, and
  there is no redirect here. StoreKit sells the pack on the device, and gives
  the app a signed transaction (a JWS) which the page posts to us.

  We trust nothing but that signature. It is ES256 with Apple's certificate
  chain inside; the chain must lead to the Apple Root CA G3 that ships with
  this app (pinned by fingerprint below), and the certificates must carry the
  markers Apple puts on the ones allowed to sign for the App Store. Then the
  transaction must be for THIS app, for a product we sell, not revoked, and
  bought for THIS account: the app passes StoreKit an `appAccountToken`
  derived from the user id, and Apple signs it into the transaction, so a
  receipt lifted from someone else's phone credits nobody.

  The ledger's `reference` (`"apple:<transactionId>"`) makes it idempotent.
  The app only tells StoreKit a purchase is finished after we say so; until
  then StoreKit redelivers it on every launch, so a credit is never lost to a
  dropped connection.

  Production accepts Sandbox transactions on purpose: App Review and
  TestFlight testers buy in the sandbox, against the live server. The
  environment is recorded on the ledger row. Xcode's local StoreKit testing
  signs with a certificate of its own that leads nowhere; it is accepted
  only under `:apple_iap_allow_xcode` (dev), never in production.
  """

  require Logger

  alias TravelingPoet.Accounts.User
  alias TravelingPoet.{Apple, Credits, JWS}

  @root_path Application.app_dir(:traveling_poet, "priv/certs/AppleRootCA-G3.cer")
  @external_resource @root_path
  @root_der File.read!(@root_path)

  # Apple Root CA - G3, as published at apple.com/certificateauthority. A
  # different file here must not compile.
  @root_sha256 "63343ABFB89A6A03EBB57E9B3F5FA7BE7C4F5C756F3017B3A8C488C3653E9179"
  if Base.encode16(:crypto.hash(:sha256, @root_der)) != @root_sha256 do
    raise "priv/certs/AppleRootCA-G3.cer is not Apple Root CA - G3"
  end

  # Apple's markers: the leaf may sign for the App Store (receipts), the
  # intermediate is the Worldwide Developer Relations CA.
  @apple_markers [
    leaf: {1, 2, 840, 113_635, 100, 6, 11, 1},
    intermediate: {1, 2, 840, 113_635, 100, 6, 2, 1}
  ]

  @product_prefix ".credits."

  @doc "StoreKit product id for a pack, e.g. `travel.poet.app.credits.p50`."
  def product_id(pack_id), do: "#{Apple.bundle_id()}#{@product_prefix}#{pack_id}"

  @doc "The packs on sale in the app, with their product ids."
  def products do
    Enum.map(Credits.packs(), fn pack ->
      %{pack: pack.id, product_id: product_id(pack.id), credits: pack.credits}
    end)
  end

  @doc """
  The token the app gives StoreKit with every purchase for this user: a UUID
  made from the user id and the server's secret, so it needs no storage and
  cannot be computed by anyone else.
  """
  def app_account_token(%User{id: id}), do: app_account_token(id)

  def app_account_token(user_id) when is_integer(user_id) do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48, _::binary>> =
      :crypto.mac(:hmac, :sha256, secret(), "iap-account-token:#{user_id}")

    # version 4, variant 10: the shape StoreKit insists on
    [<<a::32>>, <<b::16>>, <<4::4, c::12>>, <<2::2, d::14>>, <<e::48>>]
    |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  defp secret,
    do: Application.get_env(:traveling_poet, TravelingPoetWeb.Endpoint)[:secret_key_base]

  @doc """
  Verifies a signed transaction and credits its pack to `user`.

  `{:ok, :credited}` and `{:ok, :duplicate}` both mean the app may finish the
  transaction. Any error means it must NOT: either it will never be valid
  (and StoreKit may as well keep it) or it belongs to a different account,
  which will finish it when that account is signed in.
  """
  def fulfil(%User{} = user, jws) do
    with {:ok, tx} <- verify(jws),
         :ok <- check(tx["bundleId"] == Apple.bundle_id(), :wrong_app),
         :ok <- check(is_nil(tx["revocationDate"]), :revoked),
         {:ok, pack} <- pack_for(tx["productId"]),
         :ok <- check(same_token?(tx["appAccountToken"], user), :wrong_account),
         {:ok, transaction_id} <- transaction_id(tx) do
      metadata = %{
        "provider" => "apple",
        "environment" => tx["environment"],
        "storefront" => tx["storefront"],
        "price_milliunits" => tx["price"],
        "currency" => tx["currency"],
        "product_id" => tx["productId"]
      }

      case Credits.purchase(user, pack.id, "apple:" <> transaction_id, metadata) do
        {:ok, :duplicate} -> {:ok, :duplicate}
        {:ok, _tx} -> {:ok, :credited}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "The payload of a signed transaction or notification, if Apple signed it."
  def verify(jws) when is_binary(jws) do
    case JWS.verify_es256_x5c(jws, root_der(), require_oids: markers()) do
      {:ok, payload} ->
        check_environment(payload)

      {:error, reason} ->
        if allow_xcode?(), do: peek_xcode(jws, reason), else: {:error, reason}
    end
  end

  def verify(_), do: {:error, :malformed}

  # A notification's environment sits one level down, in `data`.
  defp check_environment(payload) do
    environment = payload["environment"] || get_in(payload, ["data", "environment"])

    if environment in ["Production", "Sandbox"],
      do: {:ok, payload},
      else: {:error, :wrong_environment}
  end

  # Xcode's StoreKit testing signs with a local certificate that chains to
  # nothing. Dev only: read the payload, and only if it says "Xcode".
  defp peek_xcode(jws, original_reason) do
    case JWS.peek(jws) do
      {:ok, _header, %{"environment" => "Xcode"} = payload} -> {:ok, payload}
      _ -> {:error, original_reason}
    end
  end

  defp pack_for(product_id) when is_binary(product_id) do
    prefix = Apple.bundle_id() <> @product_prefix

    with true <- String.starts_with?(product_id, prefix),
         %{} = pack <- Credits.pack(String.replace_prefix(product_id, prefix, "")) do
      {:ok, pack}
    else
      _ -> {:error, :unknown_product}
    end
  end

  defp pack_for(_), do: {:error, :unknown_product}

  defp same_token?(token, user) when is_binary(token),
    do: Plug.Crypto.secure_compare(String.downcase(token), app_account_token(user))

  defp same_token?(_, _), do: false

  defp transaction_id(%{"transactionId" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp transaction_id(_), do: {:error, :malformed}

  defp check(true, _reason), do: :ok
  defp check(_, reason), do: {:error, reason}

  @doc """
  Handles an App Store Server Notification (V2): a refund or a revoked
  purchase takes the credits back. Everything else is acknowledged and
  ignored. `{:error, _}` only for a payload Apple did not sign.
  """
  def handle_notification(signed_payload) do
    with {:ok, %{"notificationType" => type} = notification} <- verify(signed_payload) do
      if type in ["REFUND", "REVOKE"] do
        with signed_tx when is_binary(signed_tx) <-
               get_in(notification, ["data", "signedTransactionInfo"]),
             {:ok, tx} <- verify(signed_tx),
             {:ok, transaction_id} <- transaction_id(tx) do
          result =
            Credits.reverse_purchase("apple:" <> transaction_id, %{"apple_notification" => type})

          Logger.info("AppleIAP: #{type} for #{transaction_id}: #{inspect(result)}")
          {:ok, result}
        else
          other ->
            Logger.warning(
              "AppleIAP: #{type} notification without a usable transaction: #{inspect(other)}"
            )

            {:ok, :ignored}
        end
      else
        {:ok, :ignored}
      end
    end
  end

  defp root_der, do: Application.get_env(:traveling_poet, :apple_iap_root_der) || @root_der

  # Tests verify against a chain of their own, which carries no Apple markers.
  defp markers,
    do:
      if(Application.get_env(:traveling_poet, :apple_iap_root_der), do: [], else: @apple_markers)

  defp allow_xcode?,
    do: Application.get_env(:traveling_poet, :apple_iap_allow_xcode, false) == true
end
