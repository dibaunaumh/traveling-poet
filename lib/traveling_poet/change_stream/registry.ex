defmodule TravelingPoet.ChangeStream.Registry do
  @moduledoc """
  Which schemas the change stream mirrors, in FK-parent-first order so a
  backfill (and a consumer replaying it) never sees a child before its parent.

  Every Ecto schema in the app must appear in either `streamed/0` or
  `excluded/0`; `registry_test.exs` walks the compiled modules and fails the
  build when a new table is added without a decision here. Forgetting is the
  failure mode that matters: a silently missing table means the mirror is
  quietly wrong.
  """

  alias TravelingPoet.{
    Accounts,
    Books,
    Chat,
    Credits,
    Geocoder,
    Guide,
    Journal,
    Poets,
    Preferences,
    Topics,
    Trips,
    Usage
  }

  @streamed [
    Accounts.User,
    Poets.Poet,
    Poets.PathPoint,
    Trips.Trip,
    Poets.ItineraryStop,
    Topics.Topic,
    Books.Edition,
    Books.Pdf,
    Journal.Entry,
    Topics.Excursion,
    Topics.Find,
    Journal.Section,
    Journal.Media,
    Journal.Reaction,
    Journal.Marker,
    Chat.ChatMessage,
    Credits.CreditTransaction,
    Usage.UsageEvent,
    Guide.Place,
    Preferences.Preference,
    Preferences.EntryPrompt
  ]

  # geocode_cache: shared infrastructure holding raw address text typed by
  # any user; not domain state. The stream's own tables are not domain state
  # either. push_subscriptions: per-device push-service credentials (endpoint
  # + encryption keys) — anyone holding a row can notify that phone, so they
  # never leave this database. visit_events: anonymous page analytics, not
  # domain state.
  @excluded [
    TravelingPoet.Analytics.VisitEvent,
    Geocoder.CacheEntry,
    TravelingPoet.WebPush.Subscription,
    TravelingPoet.ChangeStream.Endpoint,
    TravelingPoet.ChangeStream.Event,
    TravelingPoet.ChangeStream.Fingerprint
  ]

  @doc "`[{entity_name, schema_module}]` in delivery order."
  def streamed, do: Enum.map(@streamed, &{&1.__schema__(:source), &1})

  def excluded, do: @excluded

  def entities, do: Enum.map(@streamed, & &1.__schema__(:source))

  def schema_for(entity) do
    Enum.find_value(streamed(), fn {name, mod} -> name == entity && mod end)
  end
end
