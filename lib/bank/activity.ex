defmodule Bank.Activity do
  @moduledoc """
  Imported activity ledger context (#243).

  Owns inserts and reads against `imported_activities`, plus the
  shared dedupe-key derivation and metadata redaction every importer
  must use. Future surfaces (#244 CSV upload, #245 chain sync,
  reconciler) call into this module and never touch the schema or
  table directly.

  ## Read-only ledger contract

  Inserts via this module write only to `imported_activities`. They
  never:

    * write or mutate `Bank.Decisions.ExecutionPlan`,
    * enqueue an Oban job,
    * call `Bank.AdapterClient`, the chain adapter, or any
      broadcast/signing path,
    * create an `AgentIntent` or any decision envelope.

  See the moduledoc on `Bank.Activity.ImportedActivity` for the
  one-way ledger → intent linkage contract.

  ## Idempotency

  `create_imported_activity/1` is idempotent on
  `(workspace_id, dedupe_key)`. A re-import returns
  `{:ok, :duplicate, existing}` rather than crashing on the unique
  constraint, so a CSV upload that re-uploads the same file is a
  no-op.

  ## Secret hygiene for `metadata`

  Imported source rows can carry junk fields the source author
  didn't sanitize. `redact_metadata/1` (called automatically inside
  `create_imported_activity/1`) replaces values for well-known
  secret-bearing keys with `"[REDACTED]"` before write. The list
  is intentionally narrow: callers MUST NOT pass raw secrets in
  `metadata`; this is defense-in-depth, not a substitute for
  importer-side validation.
  """

  import Ecto.Query

  alias Bank.Activity.ImportedActivity
  alias Bank.Repo

  @typedoc "Insert result for `create_imported_activity/1`."
  @type create_result ::
          {:ok, :inserted, ImportedActivity.t()}
          | {:ok, :duplicate, ImportedActivity.t()}
          | {:error, Ecto.Changeset.t()}

  @secret_metadata_keys ~w(
    authorization
    bearer
    api_key
    apikey
    private_key
    privatekey
    secret
    password
    cookie
    set-cookie
    token
    access_token
    refresh_token
    session
  )

  @doc """
  Insert one imported activity row.

  Caller passes raw attrs from the importer. The context:

    1. Redacts well-known secret keys in `attrs[:metadata]` /
       `attrs["metadata"]`.
    2. Computes a deterministic `dedupe_key` from
       `(source_type, source_ref || source_hash, occurred_at, asset,
       direction, amount)` if the caller did not supply one.
    3. Inserts via the schema changeset.
    4. On unique-constraint violation against
       `(workspace_id, dedupe_key)`, fetches and returns the
       existing row as `{:ok, :duplicate, existing}`. No raise.

  Other validation errors propagate as `{:error, changeset}`.
  """
  @spec create_imported_activity(map()) :: create_result()
  def create_imported_activity(attrs) when is_map(attrs) do
    attrs = normalise_attrs(attrs)

    case Repo.insert(ImportedActivity.create_changeset(%ImportedActivity{}, attrs)) do
      {:ok, %ImportedActivity{} = activity} ->
        {:ok, :inserted, activity}

      {:error, %Ecto.Changeset{} = changeset} ->
        if dedupe_violation?(changeset) do
          case get_by_dedupe_key(attrs[:workspace_id], attrs[:dedupe_key]) do
            %ImportedActivity{} = existing -> {:ok, :duplicate, existing}
            nil -> {:error, changeset}
          end
        else
          {:error, changeset}
        end
    end
  end

  @doc """
  List imported activities for a workspace, newest-occurred first.

  Workspace-scoped at the query layer: a `nil` workspace_id returns
  `[]`, refusing to leak rows.

  ## Options

    * `:limit` — default 100. Capped server-side.
    * `:source_type` — narrow to one of the
      `Bank.Activity.ImportedActivity.source_types/0` enum values.
  """
  @spec list_imported_activities(keyword()) :: [ImportedActivity.t()]
  def list_imported_activities(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(500)
    source_type = Keyword.get(opts, :source_type)

    if is_nil(workspace_id) or not is_binary(workspace_id) do
      []
    else
      ImportedActivity
      |> where([a], a.workspace_id == ^workspace_id)
      |> maybe_filter_source_type(source_type)
      |> order_by([a], desc: a.occurred_at, desc: a.id)
      |> limit(^limit)
      |> Repo.all()
    end
  end

  @doc """
  Look up one imported activity row by `(workspace_id, dedupe_key)`.

  Returns `nil` for unknown / cross-workspace keys.
  """
  @spec get_by_dedupe_key(String.t() | nil, String.t() | nil) ::
          ImportedActivity.t() | nil
  def get_by_dedupe_key(workspace_id, dedupe_key)
      when is_binary(workspace_id) and is_binary(dedupe_key) do
    Repo.one(
      from a in ImportedActivity,
        where: a.workspace_id == ^workspace_id and a.dedupe_key == ^dedupe_key
    )
  end

  def get_by_dedupe_key(_workspace_id, _dedupe_key), do: nil

  @doc """
  Compute the deterministic dedupe key from a (possibly partial)
  attrs map. Pure function; safe to call from importers before the
  insert path.

  The seed concatenates every field that should disambiguate two
  rows on the same source ledger. Either `source_ref` or
  `source_hash` MUST be present — the schema enforces this at insert
  time as well, so this function returns `nil` if neither is set.
  """
  @spec compute_dedupe_key(map()) :: String.t() | nil
  def compute_dedupe_key(attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    source_handle =
      case {attrs["source_ref"], attrs["source_hash"]} do
        {ref, _} when is_binary(ref) and ref != "" -> "ref:" <> ref
        {_, hash} when is_binary(hash) and hash != "" -> "hash:" <> hash
        _ -> nil
      end

    if is_nil(source_handle) do
      nil
    else
      seed =
        [
          to_seed(attrs["source_type"]),
          source_handle,
          to_seed(attrs["occurred_at"]),
          to_seed(attrs["asset"]),
          to_seed(attrs["direction"]),
          to_seed(attrs["amount"])
        ]
        |> Enum.join("|")

      :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower)
    end
  end

  @doc """
  Replace values for well-known secret-bearing keys with
  `"[REDACTED]"`. Pure function; safe to call independent of insert.
  """
  @spec redact_metadata(map()) :: map()
  def redact_metadata(metadata) when is_map(metadata) do
    Map.new(metadata, fn {k, v} ->
      if secret_key?(k) do
        {k, "[REDACTED]"}
      else
        {k, v}
      end
    end)
  end

  def redact_metadata(other), do: other

  # --- internals ---------------------------------------------------------

  defp normalise_attrs(attrs) do
    attrs = stringify_keys(attrs)
    metadata = Map.get(attrs, "metadata", %{}) |> redact_metadata()
    attrs = Map.put(attrs, "metadata", metadata)

    attrs =
      case Map.get(attrs, "dedupe_key") do
        key when is_binary(key) and key != "" ->
          attrs

        _ ->
          case compute_dedupe_key(attrs) do
            nil -> attrs
            key -> Map.put(attrs, "dedupe_key", key)
          end
      end

    # Preserve the caller-friendly atom-key shape for context-side
    # lookups (e.g. dedupe-violation re-fetch) by mirroring back to
    # `:workspace_id` / `:dedupe_key` atoms.
    attrs
    |> atomise_known_keys([
      :workspace_id,
      :dedupe_key,
      :source_type,
      :source_ref,
      :source_hash,
      :occurred_at,
      :asset,
      :chain,
      :amount,
      :direction,
      :from_address,
      :to_address,
      :counterparty_id,
      :tx_hash,
      :bank_ref,
      :status,
      :provenance,
      :confidence,
      :metadata
    ])
  end

  defp dedupe_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          Keyword.get(opts, :constraint_name) ==
            "imported_activities_workspace_dedupe_uniq"
    end)
  end

  defp maybe_filter_source_type(query, nil), do: query

  defp maybe_filter_source_type(query, source_type) when is_atom(source_type) do
    where(query, [a], a.source_type == ^source_type)
  end

  defp maybe_filter_source_type(query, _), do: query

  defp secret_key?(key) when is_binary(key) do
    key |> String.downcase() |> Kernel.in(@secret_metadata_keys)
  end

  defp secret_key?(key) when is_atom(key) do
    key |> Atom.to_string() |> secret_key?()
  end

  defp secret_key?(_), do: false

  defp to_seed(nil), do: ""
  defp to_seed(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_seed(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp to_seed(value) when is_binary(value), do: value
  defp to_seed(value) when is_atom(value), do: Atom.to_string(value)
  defp to_seed(value), do: inspect(value)

  defp stringify_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp atomise_known_keys(attrs, atom_keys) do
    Enum.reduce(atom_keys, attrs, fn atom_key, acc ->
      string_key = Atom.to_string(atom_key)

      cond do
        Map.has_key?(acc, atom_key) ->
          acc

        Map.has_key?(acc, string_key) ->
          {value, acc} = Map.pop(acc, string_key)
          Map.put(acc, atom_key, value)

        true ->
          acc
      end
    end)
  end
end
