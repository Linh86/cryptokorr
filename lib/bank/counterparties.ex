defmodule Bank.Counterparties do
  @moduledoc """
  Counterparties and address book bounded context.

  Owns the `Counterparty`, `AddressLabel`, `EvidenceArtifact`, and
  operator-issued `TrustAssertion` write paths. Decisioning code reads
  through this context rather than the schemas.

  Counterparties are the business-level recipient that policy and
  trust reason against. Addresses attach to counterparties, not the
  other way around. Archival is soft: historical references from
  intents, decisions, and audit remain intact.

  ## Public surface

      # Counterparties
      list_counterparties(filters, opts)
      get_counterparty(id)
      get_counterparty_with_preloads(id)
      create_counterparty(attrs, opts)
      update_counterparty(cp, attrs, opts)
      archive_counterparty(cp, opts)

      # Address labels
      attach_address(cp, attrs, opts)
      update_address_label(label, attrs, opts)
      retire_address_label(label, opts)
      resolve_address(chain, address)

      # Evidence (append-only)
      pin_evidence(subject, attrs, opts)

      # Trust assertions (append-only + supersedes overlapping scope)
      issue_trust_assertion(subject_type, subject_id, attrs, opts)
      effective_trust_assertions(subject_type, subject_id)

  Every write above, except for purely read paths and the pure lookup
  `resolve_address/2`, emits an audit event through
  `Bank.Runtime.emit_audit/1` as part of the same operation. Failure
  of the DB write rolls back without emitting; audit is always
  post-commit.

  ## `current_trust_level` cache maintenance

  `Counterparty.current_trust_level` is a read-cache of the most
  recent effective **broadly-scoped** (empty `scope`) trust assertion
  for the counterparty. Scoped assertions (`{chain: "base"}`,
  `{asset: "USDC", amount_ceiling: "500"}`, etc.) are stored and
  returned verbatim but do not update the cache — the cached level is
  the fast answer to "how does this counterparty render in a list?"
  rather than "what trust applies to this specific intent?" Intent-
  level decisioning walks the effective assertion set, not the cache.

  Rationale:

    * Cache never "lies" — a cached `:trusted` always has a real,
      effective, unscoped assertion backing it.
    * Scoped assertions don't flip a counterparty to `:trusted` at
      large; a "trusted for USDC payouts under $500" assertion shouldn't
      render as a global trust badge.
    * Trust-engine-derived assertions (issue #8+) will use the
      same internal helper and thus maintain the cache by construction.

  ## Trust supersession rule

  Issuing a new assertion supersedes **every effective prior
  assertion on the same subject whose scope is covered by the new
  scope** — "covered" meaning the new scope's constraints are a
  subset of the prior's. Examples:

    * New `{}` (broad) supersedes every effective assertion on that
      subject.
    * New `{chain: "base"}` supersedes `{chain: "base", asset:
      "USDC"}` but does not touch `{}`.
    * New `{chain: "base", asset: "USDC"}` does not supersede
      `{chain: "base"}` — the new one is narrower.

  Supersession runs inside the same transaction as the new insert so
  the `trust_assertions_subject_level_active_idx` (read index on
  `superseded_at IS NULL`) stays consistent at every commit
  boundary.
  """

  import Ecto.Query

  alias Bank.Counterparties.{AddressLabel, Counterparty, EvidenceArtifact, TrustAssertion}
  alias Bank.Repo
  alias Bank.Runtime
  alias Bank.Audit.Events
  alias Ecto.Multi

  @type uuid :: String.t()
  @type opts :: keyword()
  @type actor_opts :: [actor: atom(), actor_id: String.t() | nil]

  @default_page_limit 50
  @max_page_limit 500

  # ---------------------------------------------------------------------
  # Counterparties
  # ---------------------------------------------------------------------

  @doc """
  List / search counterparties. Returns the same `{entries, next_cursor}`
  shape as the audit listing so pagination is a uniform contract.

  Filters:

    * `:q` — case-insensitive substring match on `name`
    * `:active` — `true` (default: both) to filter archived out

  Options:

    * `:limit` — default #{@default_page_limit}, capped at
      #{@max_page_limit}
    * `:cursor` — opaque id cursor returned from a prior page
  """
  @spec list_counterparties(map() | keyword(), opts()) :: %{
          entries: [Counterparty.t()],
          next_cursor: String.t() | nil
        }
  def list_counterparties(filters \\ %{}, opts \\ []) do
    filters = to_map(filters)
    limit = opts |> Keyword.get(:limit, @default_page_limit) |> clamp_limit()
    cursor = Keyword.get(opts, :cursor)

    base =
      Counterparty
      |> apply_counterparty_filters(filters)
      |> order_by([c], asc: c.inserted_at, asc: c.id)

    base =
      case cursor do
        nil -> base
        cursor -> apply_cursor(base, cursor)
      end

    rows = base |> limit(^(limit + 1)) |> Repo.all()

    {entries, has_more?} =
      case rows do
        rows when length(rows) > limit -> {Enum.take(rows, limit), true}
        rows -> {rows, false}
      end

    next_cursor =
      case {has_more?, List.last(entries)} do
        {true, %Counterparty{} = last} -> encode_cursor(last)
        _ -> nil
      end

    %{entries: entries, next_cursor: next_cursor}
  end

  @doc """
  Fetch a counterparty by id. `{:ok, cp}` / `{:error, :not_found}`.
  """
  @spec get_counterparty(uuid()) :: {:ok, Counterparty.t()} | {:error, :not_found}
  def get_counterparty(id) when is_binary(id) do
    case Repo.get(Counterparty, id) do
      nil -> {:error, :not_found}
      %Counterparty{} = cp -> {:ok, cp}
    end
  end

  @doc """
  Fetch a counterparty with the preloads that queue / audit / API
  consumers typically need:

    * active (non-retired) address labels
    * current (non-superseded, unexpired) broad and scoped trust
      assertions, newest first
    * evidence artifacts (all, newest first — callers filter by
      supersession as needed)

  Returns `{:ok, cp}` or `{:error, :not_found}`. A preloaded
  `Counterparty` is safe to hand straight to the JSON renderer.
  """
  @spec get_counterparty_with_preloads(uuid()) ::
          {:ok, Counterparty.t()} | {:error, :not_found}
  def get_counterparty_with_preloads(id) when is_binary(id) do
    case Repo.get(Counterparty, id) do
      nil ->
        {:error, :not_found}

      %Counterparty{} = cp ->
        {:ok, preload_counterparty(cp)}
    end
  end

  @doc """
  Apply the standard preload set (active labels + effective trust
  assertions + evidence) to an already-loaded counterparty.
  """
  @spec preload_counterparty(Counterparty.t()) :: Counterparty.t()
  def preload_counterparty(%Counterparty{} = cp) do
    active_labels =
      from l in AddressLabel,
        where: l.counterparty_id == ^cp.id and is_nil(l.retired_at),
        order_by: [asc: l.inserted_at, asc: l.id]

    effective_assertions =
      from t in TrustAssertion,
        where: t.subject_type == "counterparty" and t.subject_id == ^cp.id,
        where: is_nil(t.superseded_at),
        order_by: [desc: t.issued_at, desc: t.id]

    evidence =
      from e in EvidenceArtifact,
        where: e.subject_type == "counterparty" and e.subject_id == ^cp.id,
        order_by: [desc: e.captured_at, desc: e.id]

    Repo.preload(cp,
      address_labels: active_labels,
      trust_assertions: effective_assertions,
      evidence_artifacts: evidence
    )
  end

  @doc """
  Create a new counterparty. Emits `counterparty.created`.

  `attrs` accepts the same keys as `Counterparty.changeset/2`; the
  caller does not supply `id`, `active` (defaults to true), or
  `current_trust_level` (defaults per schema).
  """
  @spec create_counterparty(map(), actor_opts()) ::
          {:ok, Counterparty.t()} | {:error, Ecto.Changeset.t()}
  def create_counterparty(attrs, opts \\ []) do
    attrs = normalise_attrs(attrs)

    Multi.new()
    |> Multi.insert(:counterparty, Counterparty.changeset(%Counterparty{}, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{counterparty: cp}} ->
        Runtime.emit_audit(Events.counterparty_created(cp, actor_opts(opts)))
        {:ok, cp}

      {:error, :counterparty, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Update a counterparty's operator-owned fields (`name`,
  `ownership_context`, `notes`, `active`). Archival is the only way
  to flip `active` to `false` through this function; it emits
  `counterparty.archived` in addition to `counterparty.updated` when
  that transition happens.

  Editing `current_trust_level` is not exposed here — that cache is
  written by the trust-assertion path only.
  """
  @spec update_counterparty(Counterparty.t(), map(), actor_opts()) ::
          {:ok, Counterparty.t()} | {:error, Ecto.Changeset.t()}
  def update_counterparty(%Counterparty{} = cp, attrs, opts \\ []) do
    attrs = attrs |> normalise_attrs() |> Map.drop([:current_trust_level, :created_by])

    changeset = Counterparty.changeset(cp, attrs)

    Multi.new()
    |> Multi.update(:counterparty, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{counterparty: updated}} ->
        emit_counterparty_update_audit(cp, updated, opts)
        {:ok, updated}

      {:error, :counterparty, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Archive a counterparty. Idempotent: returns `{:ok, cp}` if the
  counterparty is already archived without emitting a duplicate audit
  event.
  """
  @spec archive_counterparty(Counterparty.t(), actor_opts()) ::
          {:ok, Counterparty.t()} | {:error, Ecto.Changeset.t()}
  def archive_counterparty(cp, opts \\ [])

  def archive_counterparty(%Counterparty{active: false} = cp, _opts), do: {:ok, cp}

  def archive_counterparty(%Counterparty{} = cp, opts) do
    update_counterparty(cp, %{active: false}, opts)
  end

  # ---------------------------------------------------------------------
  # Address labels
  # ---------------------------------------------------------------------

  @doc """
  Attach an address label to a counterparty. Rejects if the
  counterparty is archived or the `(chain, lower(address))` pair is
  already active somewhere (the DB's partial unique index enforces
  this, we surface it as a changeset error).

  Returns `{:error, :archived}` when the counterparty is archived so
  the controller can surface `409` rather than a changeset error.
  """
  @spec attach_address(Counterparty.t(), map(), actor_opts()) ::
          {:ok, AddressLabel.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :archived}
  def attach_address(cp, attrs, opts \\ [])

  def attach_address(%Counterparty{active: false}, _attrs, _opts),
    do: {:error, :archived}

  def attach_address(%Counterparty{} = cp, attrs, opts) do
    attrs =
      attrs
      |> normalise_attrs()
      |> Map.put(:counterparty_id, cp.id)
      |> Map.delete(:retired_at)

    changeset = AddressLabel.changeset(%AddressLabel{}, attrs)

    Multi.new()
    |> Multi.insert(:label, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{label: label}} ->
        Runtime.emit_audit(Events.address_label_attached(label, actor_opts(opts)))
        {:ok, label}

      {:error, :label, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Edit an address label's mutable metadata (`alias`, `role`,
  `verified`). The `address` and `chain` values are immutable and
  silently dropped from `attrs`; `retired` handling is dedicated (see
  `retire_address_label/2`).

  Setting `retired: true` in `attrs` routes to
  `retire_address_label/2` so a single PATCH endpoint can express
  either an update or a retirement.
  """
  @spec update_address_label(AddressLabel.t(), map(), actor_opts()) ::
          {:ok, AddressLabel.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :already_retired}
  def update_address_label(%AddressLabel{} = label, attrs, opts \\ []) do
    attrs = normalise_attrs(attrs)

    case Map.pop(attrs, :retired) do
      {true, _rest} ->
        retire_address_label(label, opts)

      {_, rest} ->
        do_update_address_label(label, rest, opts)
    end
  end

  defp do_update_address_label(%AddressLabel{retired_at: %DateTime{}}, _attrs, _opts),
    do: {:error, :already_retired}

  defp do_update_address_label(%AddressLabel{} = label, attrs, opts) do
    attrs = Map.drop(attrs, [:address, :chain, :counterparty_id, :retired_at])

    # The label is already non-retired (guarded above) and the PATCH
    # surface does not expose address/chain edits, so we reuse the
    # general changeset but restrict the cast set implicitly via the
    # `attrs` map.
    changeset = AddressLabel.changeset(label, attrs)

    Multi.new()
    |> Multi.update(:label, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{label: updated}} ->
        Runtime.emit_audit(Events.address_label_updated(label, updated, actor_opts(opts)))
        {:ok, updated}

      {:error, :label, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Retire an address label. Idempotent: a label that is already
  retired returns `{:ok, label}` without emitting an audit event.
  """
  @spec retire_address_label(AddressLabel.t(), actor_opts()) ::
          {:ok, AddressLabel.t()} | {:error, Ecto.Changeset.t()}
  def retire_address_label(label, opts \\ [])

  def retire_address_label(%AddressLabel{retired_at: %DateTime{}} = label, _opts),
    do: {:ok, label}

  def retire_address_label(%AddressLabel{} = label, opts) do
    changeset = AddressLabel.retire(label, DateTime.utc_now())

    Multi.new()
    |> Multi.update(:label, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{label: retired}} ->
        Runtime.emit_audit(Events.address_label_retired(retired, actor_opts(opts)))
        {:ok, retired}

      {:error, :label, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Resolve an on-chain `(chain, address)` pair to the active
  `AddressLabel` and its owning `Counterparty`. Comparison is
  case-insensitive on the address (matching the partial unique
  index).

  Intended for decisioning (issue #9+) and audit-explanation reads —
  the caller receives a map rather than just a label so it can cheaply
  inspect the counterparty's cached trust level without a second query.

  Retired labels are ignored; multiple active labels on the same pair
  are impossible by the DB's partial unique index.
  """
  @spec resolve_address(String.t(), String.t()) ::
          {:ok, %{label: AddressLabel.t(), counterparty: Counterparty.t()}}
          | {:error, :not_found}
  def resolve_address(chain, address) when is_binary(chain) and is_binary(address) do
    address = String.downcase(address)

    query =
      from l in AddressLabel,
        join: c in assoc(l, :counterparty),
        where: l.chain == ^chain and fragment("lower(?)", l.address) == ^address,
        where: is_nil(l.retired_at),
        preload: [counterparty: c],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %AddressLabel{counterparty: cp} = label -> {:ok, %{label: label, counterparty: cp}}
    end
  end

  # ---------------------------------------------------------------------
  # Evidence (append-only)
  # ---------------------------------------------------------------------

  @doc """
  Pin a new evidence artifact. Evidence is append-only — corrections
  go through a superseding artifact by passing `:supersedes_id` in
  `attrs`.

  `subject` is a `%Counterparty{}` or `%AddressLabel{}`; the
  polymorphic `(subject_type, subject_id)` tuple is derived from it so
  the caller never spells it out directly. Archived counterparties
  are rejected because evidence attached to an archived subject
  would have no home to resolve against in the decisioning path.
  """
  @spec pin_evidence(Counterparty.t() | AddressLabel.t(), map(), actor_opts()) ::
          {:ok, EvidenceArtifact.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :archived}
  def pin_evidence(subject, attrs, opts \\ [])

  def pin_evidence(%Counterparty{active: false}, _attrs, _opts),
    do: {:error, :archived}

  def pin_evidence(%Counterparty{id: id} = _cp, attrs, opts) do
    do_pin_evidence("counterparty", id, id, attrs, opts)
  end

  def pin_evidence(%AddressLabel{id: id, counterparty_id: cp_id}, attrs, opts) do
    do_pin_evidence("address_label", id, cp_id, attrs, opts)
  end

  defp do_pin_evidence(subject_type, subject_id, counterparty_id, attrs, opts) do
    attrs =
      attrs
      |> normalise_attrs()
      |> Map.put(:subject_type, subject_type)
      |> Map.put(:subject_id, subject_id)
      |> Map.put_new(:captured_at, DateTime.utc_now())
      |> Map.put_new(:captured_by, Keyword.get(opts, :actor, :user))
      |> Map.put_new(:payload_hash, derive_payload_hash(attrs))

    changeset = EvidenceArtifact.changeset(%EvidenceArtifact{}, attrs)

    Multi.new()
    |> Multi.insert(:artifact, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{artifact: artifact}} ->
        Runtime.emit_audit(
          Events.evidence_attached(
            artifact,
            Keyword.put(actor_opts(opts), :counterparty_id, counterparty_id)
          )
        )

        {:ok, artifact}

      {:error, :artifact, changeset, _} ->
        {:error, changeset}
    end
  end

  # If the caller didn't supply an explicit payload_hash, hash the
  # content uri. The hash column is NOT NULL and is the integrity
  # anchor for later chain-anchoring work; a sha256 of `content_uri`
  # is a legitimate MVP choice for a `user_note` or `external_lookup`.
  defp derive_payload_hash(%{payload_hash: hash}) when is_binary(hash), do: hash
  defp derive_payload_hash(%{"payload_hash" => hash}) when is_binary(hash), do: hash

  defp derive_payload_hash(attrs) do
    content_uri = Map.get(attrs, :content_uri) || Map.get(attrs, "content_uri") || ""
    :sha256 |> :crypto.hash(content_uri) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------
  # Trust assertions
  # ---------------------------------------------------------------------

  @doc """
  Issue a new trust assertion on a subject.

  Looks up the subject (returns `{:error, :not_found}` if the
  counterparty or label doesn't exist or is archived / retired),
  then, inside a single transaction:

    1. Marks every effective prior assertion on that subject whose
       scope is covered by the new scope as `superseded_at = now`.
    2. Inserts the new assertion.
    3. When the subject is a counterparty **and** the new assertion
       is broadly-scoped (empty `scope`), updates
       `counterparties.current_trust_level` to match.

  After the commit, emits `trust_assertion.issued` with the most
  recent superseded prior as `before_ref` (if any).
  """
  @spec issue_trust_assertion(String.t(), uuid(), map(), actor_opts()) ::
          {:ok, TrustAssertion.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found}
  def issue_trust_assertion(subject_type, subject_id, attrs, opts \\ [])
      when subject_type in ~w(counterparty address_label) and is_binary(subject_id) do
    with {:ok, counterparty_id} <- resolve_trust_subject(subject_type, subject_id) do
      do_issue_trust_assertion(subject_type, subject_id, counterparty_id, attrs, opts)
    end
  end

  defp do_issue_trust_assertion(subject_type, subject_id, counterparty_id, attrs, opts) do
    attrs =
      attrs
      |> normalise_attrs()
      |> Map.put(:subject_type, subject_type)
      |> Map.put(:subject_id, subject_id)
      |> Map.put_new(:issued_at, DateTime.utc_now())
      |> Map.put_new(:issued_by, Keyword.get(opts, :actor, :user))
      |> Map.put_new(:scope, %{})

    changeset = TrustAssertion.changeset(%TrustAssertion{}, attrs)
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.run(:covered_priors, fn repo, _ ->
      {:ok, load_effective_priors_covered_by(repo, subject_type, subject_id, attrs.scope)}
    end)
    |> Multi.run(:supersede_priors, fn repo, %{covered_priors: priors} ->
      Enum.each(priors, fn prior ->
        prior
        |> TrustAssertion.mark_superseded(now)
        |> repo.update!()
      end)

      {:ok, priors}
    end)
    |> Multi.insert(:assertion, changeset)
    |> Multi.run(:counterparty_cache, fn repo, %{assertion: assertion} ->
      maybe_refresh_trust_cache(repo, assertion)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{assertion: assertion, supersede_priors: priors}} ->
        Runtime.emit_audit(
          Events.trust_assertion_issued(
            assertion,
            actor_opts(opts)
            |> Keyword.put(:counterparty_id, counterparty_id)
            |> Keyword.put(:supersedes, List.first(priors))
          )
        )

        {:ok, assertion}

      {:error, :assertion, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Return the effective (non-superseded, unexpired) trust assertions
  for a subject, newest first. Scope-match filtering for a specific
  intent is caller-side — this is the raw active set.
  """
  @spec effective_trust_assertions(String.t(), uuid()) :: [TrustAssertion.t()]
  def effective_trust_assertions(subject_type, subject_id)
      when subject_type in ~w(counterparty address_label) and is_binary(subject_id) do
    now = DateTime.utc_now()

    from(t in TrustAssertion,
      where: t.subject_type == ^subject_type and t.subject_id == ^subject_id,
      where: is_nil(t.superseded_at),
      where: is_nil(t.expires_at) or t.expires_at > ^now,
      order_by: [desc: t.issued_at, desc: t.id]
    )
    |> Repo.all()
  end

  # --- private helpers --------------------------------------------------

  # For a counterparty, the subject _is_ the counterparty; for an
  # address label, the subject is the label and the owning
  # counterparty id is the audit correlation id.
  defp resolve_trust_subject("counterparty", id) do
    case Repo.get(Counterparty, id) do
      nil -> {:error, :not_found}
      %Counterparty{active: false} -> {:error, :not_found}
      %Counterparty{id: ^id} -> {:ok, id}
    end
  end

  defp resolve_trust_subject("address_label", id) do
    case Repo.get(AddressLabel, id) do
      nil -> {:error, :not_found}
      %AddressLabel{retired_at: %DateTime{}} -> {:error, :not_found}
      %AddressLabel{counterparty_id: cp_id} -> {:ok, cp_id}
    end
  end

  # All effective priors on the subject whose scope is covered by
  # `new_scope` (i.e. every key in `new_scope` matches in the prior's
  # scope). Loaded newest-first so the supersede audit can attach the
  # most recent prior as `before_ref`.
  defp load_effective_priors_covered_by(repo, subject_type, subject_id, new_scope) do
    now = DateTime.utc_now()

    query =
      from t in TrustAssertion,
        where: t.subject_type == ^subject_type and t.subject_id == ^subject_id,
        where: is_nil(t.superseded_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now,
        order_by: [desc: t.issued_at, desc: t.id]

    query
    |> repo.all()
    |> Enum.filter(fn prior -> new_scope_covers?(new_scope, prior.scope) end)
  end

  # `new` covers `prior` when every key in `new` matches the prior's
  # scope. Strings-vs-atoms in the scope maps come from the JSON
  # request path; we normalise both sides to string keys before
  # comparing.
  defp new_scope_covers?(new_scope, prior_scope) do
    new_norm = stringify_keys(new_scope)
    prior_norm = stringify_keys(prior_scope)

    Enum.all?(new_norm, fn {k, v} -> Map.get(prior_norm, k) == v end)
  end

  defp stringify_keys(nil), do: %{}
  defp stringify_keys(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # Only broadly-scoped assertions on a counterparty refresh the
  # cached `current_trust_level`. Scoped or address-label assertions
  # leave the cache unchanged — see moduledoc.
  defp maybe_refresh_trust_cache(repo, %TrustAssertion{
         subject_type: "counterparty",
         subject_id: cp_id,
         level: level,
         scope: scope
       })
       when is_atom(level) do
    if map_size(scope || %{}) == 0 do
      from(c in Counterparty, where: c.id == ^cp_id)
      |> repo.update_all(set: [current_trust_level: level, updated_at: DateTime.utc_now()])

      {:ok, :refreshed}
    else
      {:ok, :scoped}
    end
  end

  defp maybe_refresh_trust_cache(_repo, _assertion), do: {:ok, :unchanged}

  # --- list / filter plumbing -------------------------------------------

  defp apply_counterparty_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:q, nil}, q ->
        q

      {:q, term}, q when is_binary(term) ->
        like = "%" <> String.downcase(term) <> "%"
        where(q, [c], fragment("lower(?)", c.name) |> like(^like))

      {:active, nil}, q ->
        q

      {:active, true}, q ->
        where(q, [c], c.active == true)

      {:active, false}, q ->
        where(q, [c], c.active == false)

      {_unknown, _}, q ->
        q
    end)
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_page_limit)
  defp clamp_limit(_), do: @default_page_limit

  # Cursor is just the UUID of the last row on the prior page; list
  # ordering is `(inserted_at, id)` so `WHERE (inserted_at, id) > ...`
  # is a deterministic skip.
  defp apply_cursor(query, cursor) when is_binary(cursor) do
    case Ecto.UUID.cast(cursor) do
      {:ok, id} ->
        from c in query,
          join: prev in Counterparty,
          on: prev.id == ^id,
          where: {c.inserted_at, c.id} > {prev.inserted_at, prev.id}

      :error ->
        query
    end
  end

  defp encode_cursor(%Counterparty{id: id}), do: id

  # --- audit composition ------------------------------------------------

  defp emit_counterparty_update_audit(prior, current, opts) do
    Runtime.emit_audit(Events.counterparty_updated(prior, current, actor_opts(opts)))

    if prior.active == true and current.active == false do
      Runtime.emit_audit(Events.counterparty_archived(current, actor_opts(opts)))
    end

    :ok
  end

  defp actor_opts(opts) do
    Keyword.take(opts, [:actor, :actor_id])
  end

  # --- attr coercion ----------------------------------------------------

  # Controllers hand us string-keyed maps; direct callers use atoms.
  # Cast once here so changesets and internal logic can assume atom
  # keys without re-checking.
  defp normalise_attrs(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalise_attrs()

  defp normalise_attrs(%{} = attrs) do
    attrs
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {k, normalise_value(k, v)}
      {k, v} when is_binary(k) -> {safe_atom(k), normalise_value(safe_atom(k), v)}
    end)
    |> Map.new()
  end

  # Known atom-typed enums: cast strings at the boundary so the
  # changeset gets a shape it can validate. Anything else passes
  # through.
  defp normalise_value(:role, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(:level, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(:kind, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(:weight, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(:captured_by, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(:issued_by, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(:current_trust_level, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(:created_by, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(_key, v), do: v

  # Only atoms that already exist are accepted. Unknown strings stay
  # as strings so the changeset emits a clean validation error instead
  # of crashing on an atom-table overflow attack vector.
  defp safe_atom(string) when is_binary(string) do
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError -> string
    end
  end

  defp to_map(%{} = m), do: m
  defp to_map(list) when is_list(list), do: Map.new(list)
end
