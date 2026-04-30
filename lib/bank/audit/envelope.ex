defmodule Bank.Audit.Envelope do
  @moduledoc """
  Canonical construction and hashing for audit event attrs.

  The `AuditEvent` schema is the storage shape. This module is the
  *writer-side* shape: every emitter funnels through `build/1`, which
  normalises the attrs, computes `payload_hash`, and returns a map the
  `Bank.Audit` writer can hand straight to the schema changeset.

  ## Canonical payload

  The payload hashed into `payload_hash` is a canonical JSON
  serialization of the event envelope minus the fields that are not
  content (`id`, `payload_hash` itself, `inserted_at`). The canonical
  form is built by:

    1. Extracting the envelope fields (see `@canonical_fields`).
    2. Dropping keys whose value is `nil`.
    3. JSON-encoding with sorted map keys (see `canonical_iodata/1`).

  The hash is `sha256`, hex-encoded lowercase. This is an MVP choice:
  chain anchoring or signing can layer on top later by hashing this
  `payload_hash` along with an external salt.

  ## Envelope fields

  Every emitter must supply, or the builder will refuse:

    * `:actor` — one of `:user`, `:agent`, `:runtime`, `:adapter`
    * `:event_type` — structured string (see naming conventions in
      `Bank.Audit`)
    * `:subject_type` / `:subject_id` — what the event is about
    * `:correlation_id` OR an explicit `:correlation_id` of `nil` for
      runtime-scoped events (e.g. `security.paused`). Most events set
      `correlation_id` to the intent id.

  Optional fields carried through verbatim:

    * `:actor_id`, `:before_ref`, `:after_ref`, `:schema_version`,
      `:ts`

  If `:ts` is missing, the current wall time is used.
  """

  @canonical_fields [
    :actor,
    :actor_id,
    :event_type,
    :subject_type,
    :subject_id,
    :correlation_id,
    :before_ref,
    :after_ref,
    :schema_version,
    :ts
  ]

  # Schema-accepted fields that the writer carries through but the
  # canonical hash deliberately ignores. `workspace_id` lives here:
  # #158a added it to the row as a read hint without disturbing the
  # hash invariant from #161, so existing event hashes stay valid
  # even when new emissions stamp it.
  @passthrough_fields [:workspace_id]

  @required_fields [:actor, :event_type, :subject_type, :subject_id]

  @type attrs :: map()

  @doc """
  Normalise the caller's attrs into a writer-ready map.

  Returns `{:ok, attrs}` when every required field is present, or
  `{:error, {:missing_fields, [atom()]}}` otherwise. The returned map
  always includes `:ts`, `:payload_hash`, and `:schema_version`.

  The canonical hash is computed *after* defaulting `:ts` and
  `:schema_version`, so the hash on an event that omits `:ts` is
  reproducible only in combination with the stored `:ts` — exactly
  what replay needs.
  """
  @spec build(map() | keyword()) :: {:ok, attrs()} | {:error, term()}
  def build(attrs) do
    raw = to_map(attrs)
    canonical = Map.take(raw, @canonical_fields)
    passthrough = Map.take(raw, @passthrough_fields)

    with :ok <- require_fields(canonical) do
      canonical =
        canonical
        |> Map.put_new(:ts, DateTime.utc_now())
        |> Map.put_new(:schema_version, "1")

      final =
        canonical
        |> Map.put(:payload_hash, payload_hash(canonical))
        |> Map.merge(passthrough)

      {:ok, final}
    end
  end

  @doc """
  Same as `build/1` but raises on missing fields. Use from internal
  emitters that have already validated their inputs.
  """
  @spec build!(map() | keyword()) :: attrs()
  def build!(attrs) do
    case build(attrs) do
      {:ok, normalised} ->
        normalised

      {:error, {:missing_fields, fields}} ->
        raise ArgumentError,
              "Bank.Audit.Envelope.build!/1 missing required fields: #{inspect(fields)}"
    end
  end

  @doc """
  Return the canonical hash for a pre-built attrs map. Exposed for
  tests that want to verify the wire-form hash.
  """
  @spec payload_hash(map()) :: String.t()
  def payload_hash(attrs) do
    attrs
    |> Map.take(@canonical_fields)
    |> canonical_iodata()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The list of fields included in the canonical payload."
  @spec canonical_fields() :: [atom()]
  def canonical_fields, do: @canonical_fields

  @doc "The list of fields an emitter must always supply."
  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  # --- internals ---------------------------------------------------------

  defp require_fields(attrs) do
    case Enum.reject(@required_fields, &Map.has_key?(attrs, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_fields, missing}}
    end
  end

  defp to_map(attrs) when is_map(attrs), do: attrs
  defp to_map(attrs) when is_list(attrs), do: Map.new(attrs)

  # Canonical JSON: sorted keys, stripped nils, stable encoding for
  # atoms and DateTime. Uses `Jason.OrderedObject` so insertion order
  # (which we control to be alphabetical by key) is preserved in the
  # emitted JSON. Hashing a `Map` directly would be non-deterministic
  # because map iteration order isn't guaranteed alphabetical.
  defp canonical_iodata(value) do
    value
    |> canonical_value()
    |> Jason.encode_to_iodata!()
  end

  defp canonical_key(k) when is_atom(k), do: Atom.to_string(k)
  defp canonical_key(k) when is_binary(k), do: k

  defp canonical_value(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp canonical_value(%Decimal{} = d), do: Decimal.to_string(d, :normal)

  defp canonical_value(v) when is_atom(v) and not is_boolean(v) and not is_nil(v),
    do: Atom.to_string(v)

  defp canonical_value(v) when is_map(v) and not is_struct(v) do
    pairs =
      v
      |> Enum.reject(fn {_k, vv} -> is_nil(vv) end)
      |> Enum.map(fn {k, vv} -> {canonical_key(k), canonical_value(vv)} end)
      |> Enum.sort_by(fn {k, _} -> k end)

    Jason.OrderedObject.new(pairs)
  end

  defp canonical_value(v) when is_list(v), do: Enum.map(v, &canonical_value/1)
  defp canonical_value(v), do: v
end
