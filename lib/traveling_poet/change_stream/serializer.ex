defmodule TravelingPoet.ChangeStream.Serializer do
  @moduledoc """
  Turns a schema struct into the JSON-ready record that goes over the wire,
  with privacy redaction applied, and hashes it for change detection.

  Redaction is by field NAME (the spec's choice), in two layers:

    * patterns matched against every key at every nesting depth — anything
      that looks like a credential (`token`, `secret`, `password`,
      `private_key`, `public_key`, `api_key`, `*_key`). `media.s3_key` is
      caught on purpose: a bucket path is an internal locator, the public
      `/media/:id` route is the address.
    * exact names per entity — the identity fields Udi chose to withhold
      (`users.email`, OAuth ids, Telegram ids) and `chat_messages.content`,
      the user's private conversation with their poet.

  Redacted fields are OMITTED, not replaced with a sentinel. A `"[redacted]"`
  email is a value a mirror will store and a support agent will try to write
  to; an absent key is unambiguous, and the key set of a record documents what
  is shareable.

  Free-form map columns (`poets.settings`, `usage_events.metadata`,
  `chat_messages.attachments`) are walked with the same patterns plus
  `email`, so a credential stored under a nested key is dropped too. A future
  key named unlike anything here would leak; that is the known limit of
  name-based redaction.
  """

  @redact_patterns [
    ~r/token/,
    ~r/secret/,
    ~r/password/,
    ~r/private_key/,
    ~r/public_key/,
    ~r/api_key/,
    ~r/_key$/
  ]

  @redact_exact %{
    "users" => ~w(email google_id apple_id telegram_chat_id telegram_username),
    "chat_messages" => ~w(content),
    # the calendar events behind a trip (ids, dates, locations): calendar content
    "trips" => ~w(signals)
  }

  # Nested maps are user-shaped data; be a little stricter there.
  @nested_exact ~w(email)

  @doc "True when a top-level field of `entity` must not leave the app."
  def redacted_field?(entity, field) when is_atom(field),
    do: redacted_field?(entity, Atom.to_string(field))

  def redacted_field?(entity, field) when is_binary(field) do
    field in Map.get(@redact_exact, entity, []) or pattern_match?(field)
  end

  @doc "Per-entity list of omitted top-level fields, for the consumer contract."
  def redacted_fields(entity, schema) do
    schema.__schema__(:fields)
    |> Enum.map(&Atom.to_string/1)
    |> Enum.filter(&redacted_field?(entity, &1))
  end

  @doc "The wire record: string keys, JSON scalars, redacted fields absent."
  def encode(entity, %schema{} = struct) do
    schema.__schema__(:fields)
    |> Enum.reject(&redacted_field?(entity, &1))
    |> Map.new(fn field -> {Atom.to_string(field), normalize(Map.get(struct, field))} end)
  end

  @doc "Deterministic sha256 over the encoded record."
  def fingerprint(record) when is_map(record) do
    record
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # Sorted keys at every level: Elixir maps over 32 keys iterate in hash
  # order, which is stable but not something to build a hash contract on.
  defp canonical(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn {k, v} -> {k, canonical(v)} end)
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(other), do: other

  defp normalize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  # Naive timestamps in this app are UTC (Ecto's default `timestamps()`).
  defp normalize(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp normalize(%Date{} = d), do: Date.to_iso8601(d)
  defp normalize(%Decimal{} = d), do: Decimal.to_string(d)

  defp normalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.reject(fn {k, _} -> nested_redacted?(to_string(k)) end)
    |> Map.new(fn {k, v} -> {to_string(k), normalize(v)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  defp normalize(bin) when is_binary(bin) do
    if String.valid?(bin), do: bin, else: Base.encode64(bin)
  end

  defp normalize(other), do: other

  defp nested_redacted?(key), do: key in @nested_exact or pattern_match?(key)

  defp pattern_match?(name), do: Enum.any?(@redact_patterns, &Regex.match?(&1, name))
end
