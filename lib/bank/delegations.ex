defmodule Bank.Delegations do
  @moduledoc """
  Control-plane model of smart-account delegation state.

  The authoritative delegation lives on-chain, and the mechanics of
  granting, signing, and revoking happen in the TypeScript adapter
  (see `docs/bank-v0.1-runtime-flow-and-api.md §3`). This module is
  the Phoenix-side durable projection of that state: just enough
  information for routing, policy evaluation, and the operator
  dashboard to answer three questions without making an adapter
  round-trip:

    1. Does this smart account currently have an active delegation?
    2. Is a revoke in flight? (affects execution gating)
    3. When does the delegation window expire? (for approval TTL
       interplay)

  ## State machine

      pending ──grant──▶ active ──revoke_requested──▶ revoking
                           │                             │
                           │                             ├──success──▶ revoked
                           │                             │
                           │                             └──failure──▶ revoke_failed ──retry──▶ revoking
                           │
                           └──expire──▶ expired

  Transitions are monotonically cautious — any state other than
  `:active` disables autonomous execution regardless of the
  surrounding decision (see `executable?/1`). In particular:

    * `:revoking` is treated as non-executable, because the revoke
      request is a commitment to stop using this delegation even
      before the chain confirms.
    * `:revoke_failed` means the adapter's on-chain revoke attempt
      could not complete cleanly (send rejected, confirmation
      timeout, sentinel reverted). The on-chain delegation is still
      live, so the row stays non-terminal, non-executable, and the
      operator can retry — `record_revoke_requested/2` accepts
      `:revoke_failed` as a prior state for that reason.
    * `:expired` prevents execution from reusing a stale window.
    * `:revoked` is terminal; a new grant produces a *new* record.

  ## Persistence

  State is durable in Postgres via the `delegations` table. The
  adapter is the source of truth on chain; this context is a
  projection that survives restart.

  ## `delegation_id` and the on-chain authority record

  `delegations.delegation_id` is an opaque string from Phoenix's
  perspective — Phoenix never parses or interprets it. The adapter
  owns its meaning. The wire-level field is stable; the on-the-wire
  encoding will be decided alongside the ZeroDev SDK integration
  described in `docs/zerodev-permissions-integration.md`. ZeroDev's
  real `permissionId` is 4 bytes (8 hex chars), and the kernel's
  on-chain `validationId` is 21 bytes; an earlier version of this
  module claimed the value was a 32-byte `permissionId` (66 hex
  chars total), which was a wrong-model assumption. Phoenix does
  not enforce any specific encoding here; the adapter accepts and
  echoes whatever string it receives.

  The architectural decision to use a Kernel v3 modular account on
  Base lives in `docs/smart-account-and-revoke-design.md` (#56).
  What survives the model correction is the wire-level field
  itself; the format-validation helpers that previously enforced
  66-char hex have been removed because they would reject every
  real ZeroDev id. The cryptographic revoke is now wired (#58 PR
  #129 + #130): rows that carry the full permission artifact set
  drive `Kernel.uninstallValidation(...)` automatically. Rows
  without artifacts continue to take the sentinel path. #58 stays
  open until a real on-chain grant + revoke confirms on Base
  Sepolia.

  ## Public API

      grant(smart_account_id, delegation_id, attrs)
      record_revoke_requested(smart_account_id, attrs)
      record_revoke_failed(smart_account_id, attrs)
      record_revoked(smart_account_id, attrs)
      record_expired(smart_account_id)
      get(smart_account_id)
      get_by_id(id)
      executable?(smart_account_id)
      apply_callback(callback_params)
      permission_dispatch_block(delegation)

  ## Permission artifacts (#58)

  Rows that have a serialized ZeroDev permission plugin attached
  participate in the cryptographic revoke path. `grant/3` accepts
  the optional artifact attrs (`:permission_blob`, `:permission_id`,
  `:validation_id`, `:kernel_version`,
  `:permission_package_version`, `:installed_at_block`,
  `:install_tx_hash`); `apply_callback/1` extracts them from a
  `params["permission"]` map on the `granted` branch and decodes
  the hex-typed fields. `permission_dispatch_block/1` produces the
  wire-shaped block that the revoke dispatch carries so the
  adapter can reconstruct the plugin without any further round-
  trip into Phoenix.
  """

  import Ecto.Query

  alias Bank.Delegations.Delegation
  alias Bank.Repo

  @grant_failure_reasons ~w(
    operator_key_missing
    chain_id_mismatch
    permission_install_failed
    permission_serialization_failed
  )

  @type smart_account_id :: String.t()

  # --- Read API -----------------------------------------------------------

  @doc """
  List all non-terminal delegations across all smart accounts.
  Returns a list of `Delegation` structs ordered by most recently created.

  Options:

    * `:workspace_id` — narrow to one workspace (#158b.2). Default
      `nil` keeps the legacy "all workspaces" path open until every
      caller is migrated.
  """
  @spec list_active(keyword()) :: [Delegation.t()]
  def list_active(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    from(d in Delegation,
      where: d.state in [:pending, :active, :revoking, :revoke_failed],
      order_by: [desc: d.inserted_at]
    )
    |> scope_delegation_to_workspace(workspace_id)
    |> Repo.all()
  end

  # Optional workspace filter for #158b.2. The `delegations` table
  # carries `workspace_id` directly (read hint added in #158a), so the
  # filter is a direct WHERE. The `nil` default leaves the query
  # untouched for legacy callers that have not been migrated.
  defp scope_delegation_to_workspace(query, nil), do: query

  defp scope_delegation_to_workspace(query, workspace_id) when is_binary(workspace_id),
    do: where(query, [d], d.workspace_id == ^workspace_id)

  @doc """
  Fetch the current (non-terminal) delegation for a smart account.
  Returns `nil` if no non-terminal delegation exists.
  """
  @spec get(smart_account_id()) :: Delegation.t() | nil
  def get(smart_account_id) when is_binary(smart_account_id) do
    Repo.one(
      from(d in Delegation,
        where:
          d.smart_account_id == ^smart_account_id and
            d.state in [:pending, :active, :revoking, :revoke_failed],
        order_by: [desc: d.inserted_at],
        limit: 1
      )
    )
  end

  @doc "Fetch a delegation by its primary key."
  @spec get_by_id(String.t()) :: {:ok, Delegation.t()} | {:error, :not_found}
  def get_by_id(id) when is_binary(id) do
    case Repo.get(Delegation, id) do
      nil -> {:error, :not_found}
      delegation -> {:ok, delegation}
    end
  end

  @doc """
  Is this smart account currently executable?

  `true` iff there's an `:active` record whose `:expires_at` (if set)
  is in the future. Missing records, revoking records, and revoked or
  expired records all return `false` — the control plane fails closed.
  """
  @spec executable?(smart_account_id(), DateTime.t()) :: boolean()
  def executable?(smart_account_id, now \\ DateTime.utc_now()) do
    case get(smart_account_id) do
      %Delegation{state: :active, expires_at: nil} ->
        true

      %Delegation{state: :active, expires_at: %DateTime{} = exp} ->
        DateTime.compare(exp, now) == :gt

      _ ->
        false
    end
  end

  # --- Write API ----------------------------------------------------------

  @doc """
  Register a fresh delegation. Creates a new row in :active state.
  If a non-terminal delegation already exists, returns `{:error, :already_exists}`.

  ## Workspace scope (#158d-c)

  Pass `:workspace_id` in `attrs` whenever the caller knows the
  workspace (operator-driven flows, demo / smoke seeders, tests).
  The new column is the read hint added by #158a; populating it
  here is what lets `delegation.state_changed` audit events from
  the adapter callback path inherit `delegation.workspace_id`
  (#158d-b's emit hook reads from the column).

  Adapter callbacks (`apply_callback/1`) are intentionally
  workspace-blind today: a callback arrives with only
  `smart_account_id` and `delegation_id`, so the resulting fresh
  row stays unscoped (`workspace_id: nil`). A future PR can add a
  smart-account → workspace lookup; until then this is the
  documented exception to "all new rows carry workspace_id".
  """
  @spec grant(smart_account_id(), String.t(), map()) ::
          {:ok, Delegation.t()} | {:error, :already_exists | Ecto.Changeset.t()}
  def grant(smart_account_id, delegation_id, attrs \\ %{})
      when is_binary(smart_account_id) and is_binary(delegation_id) do
    attrs =
      Map.merge(attrs, %{
        smart_account_id: smart_account_id,
        delegation_id: delegation_id,
        state: :active,
        granted_at: Map.get(attrs, :granted_at, DateTime.utc_now())
      })

    %Delegation{}
    |> Delegation.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, delegation} ->
        {:ok, delegation}

      {:error, %Ecto.Changeset{errors: errors} = cs} ->
        if Keyword.has_key?(errors, :smart_account_id) do
          {:error, :already_exists}
        else
          {:error, cs}
        end
    end
  end

  @doc """
  Mark a delegation as revoke-requested. From this moment the smart
  account is non-executable, even if the chain hasn't confirmed.

  `:revoke_failed` is also accepted here as a prior state: it means a
  previous revoke attempt failed on-chain and the operator is
  retrying, so the row returns to `:revoking` and the adapter will
  submit a fresh tx.

  Duplicate `:revoking` acknowledgements are idempotent. Phoenix
  records `:revoking` before dispatching the adapter worker; the
  adapter may also emit a `state=revoking` callback before touching
  chain. Treating that second acknowledgement as success keeps the
  callback path quiet while preserving the stricter rule that
  `:revoked` and `:revoke_failed` still require a prior `:revoking`
  state.

  Returns `{:ok, delegation}` or `{:error, :not_found}`.
  """
  @spec record_revoke_requested(smart_account_id(), map()) ::
          {:ok, Delegation.t()} | {:error, :not_found | :invalid_transition}
  def record_revoke_requested(smart_account_id, attrs \\ %{}) do
    transition_locked(smart_account_id, fn delegation ->
      case delegation do
        %Delegation{state: state}
        when state in [:active, :pending, :revoke_failed] ->
          delegation
          |> Delegation.revoke_requested_changeset(attrs)
          |> Repo.update()

        %Delegation{state: :revoking} ->
          {:ok, delegation}

        %Delegation{} ->
          {:error, :invalid_transition}
      end
    end)
  end

  @doc """
  Mark a delegation's on-chain revoke attempt as failed.

  Transitions `:revoking` → `:revoke_failed`. The on-chain delegation
  is still live, so the row stays non-terminal (non-executable, still
  occupying the per-smart-account uniqueness slot). The operator may
  call `record_revoke_requested/2` again to retry.

  Only `:revoking` is accepted as a prior state — reporting a failure
  without first acknowledging the revoke attempt would be meaningless.
  """
  @spec record_revoke_failed(smart_account_id(), map()) ::
          {:ok, Delegation.t()} | {:error, :not_found | :invalid_transition}
  def record_revoke_failed(smart_account_id, attrs \\ %{}) do
    transition_locked(smart_account_id, fn delegation ->
      case delegation do
        %Delegation{state: :revoking} ->
          delegation
          |> Delegation.revoke_failed_changeset(attrs)
          |> Repo.update()

        %Delegation{} ->
          {:error, :invalid_transition}
      end
    end)
  end

  @doc """
  Mark a delegation as confirmed-revoked on-chain.

  Only `:revoking` is accepted as a prior state. Failures of the
  revoke attempt itself go through `record_revoke_failed/2`, so
  reaching `:revoked` means the chain confirmed the revoke succeeded.
  """
  @spec record_revoked(smart_account_id(), map()) ::
          {:ok, Delegation.t()} | {:error, :not_found | :invalid_transition}
  def record_revoked(smart_account_id, attrs \\ %{}) do
    transition_locked(smart_account_id, fn delegation ->
      case delegation do
        %Delegation{state: :revoking} ->
          delegation
          |> Delegation.revoked_changeset(attrs)
          |> Repo.update()

        %Delegation{} ->
          {:error, :invalid_transition}
      end
    end)
  end

  @doc "Mark a delegation as expired."
  @spec record_expired(smart_account_id()) ::
          {:ok, Delegation.t()} | {:error, :not_found | :invalid_transition}
  def record_expired(smart_account_id) do
    transition_locked(smart_account_id, fn delegation ->
      case delegation do
        %Delegation{state: :active} ->
          delegation
          |> Delegation.expired_changeset()
          |> Repo.update()

        %Delegation{} ->
          {:error, :invalid_transition}
      end
    end)
  end

  # Adapter callbacks for the same `smart_account_id` can race when
  # the chain emits two events close together (e.g. `revoke_failed`
  # and a delayed-but-now-confirmed `revoked`). Without a row lock,
  # both writers read the row at `:revoking`, both pass their
  # in-memory pattern guards, and whichever `Repo.update/1` commits
  # last wins — including overwriting a terminal `:revoked` with
  # `:revoke_failed`. Mirror the `Bank.Decisions.apply_execution_callback/1`
  # fix (#314): wrap the transition in a transaction, lock the
  # current non-terminal row `FOR UPDATE`, then re-pattern-match
  # against the locked row inside the lock window. A late callback
  # whose target row has already moved to a terminal state collapses
  # to `{:error, :not_found}` (the terminal-state filter on the lock
  # query hides it) so the controller acks with
  # `accepted_with_warning` and the adapter does not retry.
  defp transition_locked(smart_account_id, transition_fn) when is_binary(smart_account_id) do
    Repo.transaction(fn ->
      case lock_active_delegation(smart_account_id) do
        nil ->
          Repo.rollback(:not_found)

        %Delegation{} = delegation ->
          case transition_fn.(delegation) do
            {:ok, %Delegation{} = updated} -> updated
            {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, %Delegation{} = d} -> {:ok, d}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_active_delegation(smart_account_id) do
    Repo.one(
      from(d in Delegation,
        where:
          d.smart_account_id == ^smart_account_id and
            d.state in [:pending, :active, :revoking, :revoke_failed],
        order_by: [desc: d.inserted_at],
        limit: 1,
        lock: "FOR UPDATE"
      )
    )
  end

  # Callback-specific lock variant that ALSO matches `delegation_id`.
  # Adapter callbacks identify the target delegation by both
  # `smart_account_id` and `delegation_id`, but the prior callback
  # path only filtered by `smart_account_id` and could land an old
  # `del_1` callback on a freshly-granted `del_2` for the same SA
  # (revoke/re-grant turnaround). Filtering on both fields makes
  # stale callbacks for retired delegations collapse to `nil` →
  # `{:error, :not_found}`, leaving the current `del_2` row
  # untouched.
  defp lock_delegation_for_callback(smart_account_id, delegation_id)
       when is_binary(smart_account_id) and is_binary(delegation_id) do
    Repo.one(
      from(d in Delegation,
        where:
          d.smart_account_id == ^smart_account_id and
            d.delegation_id == ^delegation_id and
            d.state in [:pending, :active, :revoking, :revoke_failed],
        order_by: [desc: d.inserted_at],
        limit: 1,
        lock: "FOR UPDATE"
      )
    )
  end

  # Callback-driven transition: identical envelope to
  # `transition_locked/2` but the lock query also filters on
  # `delegation_id` so a stale callback for an old delegation
  # cannot mutate a freshly-granted current row that happens to
  # share the same `smart_account_id`.
  defp transition_locked_for_callback(smart_account_id, delegation_id, transition_fn)
       when is_binary(smart_account_id) and is_binary(delegation_id) do
    Repo.transaction(fn ->
      case lock_delegation_for_callback(smart_account_id, delegation_id) do
        nil ->
          Repo.rollback(:not_found)

        %Delegation{} = delegation ->
          case transition_fn.(delegation) do
            {:ok, %Delegation{} = updated} -> updated
            {:error, %Ecto.Changeset{} = cs} -> Repo.rollback(cs)
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
    |> case do
      {:ok, %Delegation{} = d} -> {:ok, d}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_revoke_requested_for_callback(smart_account_id, delegation_id, attrs) do
    transition_locked_for_callback(smart_account_id, delegation_id, fn delegation ->
      case delegation do
        %Delegation{state: state}
        when state in [:active, :pending, :revoke_failed] ->
          delegation
          |> Delegation.revoke_requested_changeset(attrs)
          |> Repo.update()

        %Delegation{state: :revoking} ->
          {:ok, delegation}

        %Delegation{} ->
          {:error, :invalid_transition}
      end
    end)
  end

  defp record_revoke_failed_for_callback(smart_account_id, delegation_id, attrs) do
    transition_locked_for_callback(smart_account_id, delegation_id, fn delegation ->
      case delegation do
        %Delegation{state: :revoking} ->
          delegation
          |> Delegation.revoke_failed_changeset(attrs)
          |> Repo.update()

        %Delegation{} ->
          {:error, :invalid_transition}
      end
    end)
  end

  defp record_revoked_for_callback(smart_account_id, delegation_id, attrs) do
    transition_locked_for_callback(smart_account_id, delegation_id, fn delegation ->
      case delegation do
        %Delegation{state: :revoking} ->
          delegation
          |> Delegation.revoked_changeset(attrs)
          |> Repo.update()

        %Delegation{} ->
          {:error, :invalid_transition}
      end
    end)
  end

  defp record_expired_for_callback(smart_account_id, delegation_id) do
    transition_locked_for_callback(smart_account_id, delegation_id, fn delegation ->
      case delegation do
        %Delegation{state: :active} ->
          delegation
          |> Delegation.expired_changeset()
          |> Repo.update()

        %Delegation{} ->
          {:error, :invalid_transition}
      end
    end)
  end

  @doc """
  Apply a `delegation.state_changed` callback from the adapter.

  Maps adapter states to context transitions:
    - "granted" → grant (upsert: creates if not found)
    - "grant_failed" → reject without creating an active row
    - "revoking" → record_revoke_requested
    - "revoke_failed" → record_revoke_failed
    - "revoked" → record_revoked (success only)
    - "expired" → record_expired

  Returns `{:ok, delegation}` or `{:error, reason}`.
  """
  @spec apply_callback(map()) :: {:ok, Delegation.t()} | {:error, term()}
  def apply_callback(
        %{
          "smart_account_id" => smart_account_id,
          "delegation_id" => delegation_id,
          "state" => callback_state,
          "reason" => reason
        } = params
      ) do
    tx_hash = extract_tx_hash(params)

    case callback_state do
      "granted" ->
        permission = Map.get(params, "permission")
        artifact_attrs = decode_permission_artifacts(permission)

        cond do
          is_nil(permission) and reason in @grant_failure_reasons ->
            {:error, :grant_failed}

          true ->
            case get(smart_account_id) do
              nil ->
                grant(
                  smart_account_id,
                  delegation_id,
                  Map.merge(artifact_attrs, %{
                    last_reason: reason,
                    scope: Map.get(params, "scope", %{})
                  })
                )

              # Refuse to apply a `granted` callback whose
              # `delegation_id` does not match the current
              # non-terminal row. Without this guard a stale
              # callback for retired `del_old` could land on a
              # freshly-granted `del_new` and either return
              # `{:ok, del_new}` (silently acknowledging the wrong
              # delegation) or upgrade `:pending` → `:active` with
              # the stale callback's `last_reason`.
              %Delegation{delegation_id: current_id} when current_id != delegation_id ->
                {:error, :not_found}

              %Delegation{state: :pending} = delegation ->
                delegation
                |> Delegation.changeset(Map.merge(artifact_attrs, %{last_reason: reason}))
                |> Ecto.Changeset.put_change(:state, :active)
                |> Ecto.Changeset.put_change(:granted_at, DateTime.utc_now())
                |> Repo.update()

              %Delegation{state: :active} = delegation ->
                {:ok, delegation}

              _ ->
                {:error, :invalid_transition}
            end
        end

      "grant_failed" ->
        # A failed install must not create an active delegation. The
        # adapter sends this for operator-key-missing, chain mismatch,
        # install reverts, or serialization failures on the grant path.
        {:error, :grant_failed}

      "revoking" ->
        record_revoke_requested_for_callback(smart_account_id, delegation_id, %{
          last_reason: reason
        })

      "revoke_failed" ->
        record_revoke_failed_for_callback(smart_account_id, delegation_id, %{
          last_reason: reason,
          last_tx_hash: tx_hash
        })

      "revoked" ->
        record_revoked_for_callback(smart_account_id, delegation_id, %{
          last_reason: reason,
          last_tx_hash: tx_hash
        })

      "expired" ->
        record_expired_for_callback(smart_account_id, delegation_id)

      _ ->
        {:error, :unknown_state}
    end
  end

  def apply_callback(_), do: {:error, :invalid_callback}

  @doc """
  Record a browser-initiated connect request and enqueue the grant
  worker (v1.1 wired under #58).

  Writes an `intent-to-connect` audit event capturing the signed
  payload the JS hook built, then enqueues
  `Bank.Runtime.Workers.GrantDelegation` to dispatch the grant to
  the adapter. The actual on-chain install (build a ZeroDev
  permission plugin, install via sudo-signed UserOp, emit
  `granted` callback) lives in the adapter; the worker just
  forwards the request and threads outcomes onto Oban retry
  semantics.

  The eventual `delegation.state_changed{state: "granted"}`
  callback flows back through `apply_callback/1` and creates the
  delegation row with the artifact columns populated.

  Accepts a map with:
    * `:smart_account_id` — string
    * `:chain_id` — integer (must be Base or Base Sepolia)
    * `:account` — string (EOA / session key address)
    * `:delegation_payload` — map (signed payload, optional;
      threaded to the adapter for future signature verification
      and persisted on the audit trail today)

  Returns `{:ok, :accepted}` once the audit event is written and
  the worker is enqueued. The synchronous response is acceptance
  of the request, not confirmation of an active delegation —
  observe the callback path for that.
  """
  @spec request_connect(map()) :: {:ok, :accepted} | {:error, term()}
  def request_connect(
        %{
          "smart_account_id" => sa_id,
          "chain_id" => chain_id,
          "account" => account
        } = params
      )
      when is_binary(sa_id) and is_integer(chain_id) and is_binary(account) do
    with :ok <- validate_chain(chain_id),
         {:ok, _event} <- write_intent_audit(sa_id, chain_id, account),
         {:ok, _job} <- enqueue_grant_worker(sa_id, chain_id, account, params) do
      {:ok, :accepted}
    end
  end

  def request_connect(_), do: {:error, :invalid_payload}

  defp validate_chain(8453), do: :ok
  defp validate_chain(84_532), do: :ok
  defp validate_chain(_), do: {:error, :unsupported_chain}

  defp write_intent_audit(sa_id, chain_id, account) do
    Bank.Audit.append_event(%{
      actor: :user,
      event_type: "delegation.connect_requested",
      subject_type: "smart_account",
      subject_id: sa_id,
      correlation_id: nil,
      after_ref: %{
        "chain_id" => chain_id,
        "account" => account,
        "source" => "browser_wallet"
      }
    })
  end

  defp enqueue_grant_worker(sa_id, chain_id, account, params) do
    args = %{
      "smart_account_id" => sa_id,
      "chain_id" => chain_id,
      "account" => account,
      "delegation_payload" => Map.get(params, "delegation_payload"),
      "scope" => Map.get(params, "scope", %{})
    }

    args
    |> Bank.Runtime.Workers.GrantDelegation.new()
    |> Oban.insert()
  end

  @doc """
  Build the wire-shaped `permission` block for a revoke dispatch, or
  return `nil` if this row is not cryptographically revocable.

  When non-nil the result is a JSON-encodable map with hex-encoded
  ids and the base64 blob carried verbatim. The shape matches
  `priv/adapter/contract.md` v2:

      %{
        blob: "<base64>",            # serializePermissionAccount output
        permission_id: "0x...",      # 4-byte permissionId, 10 hex chars
        validation_id: "0x...",      # 21-byte validationId, 44 hex chars
        kernel_version: "0.3.1",
        package_version: "5.6.3",
        session_signer_address: "0x..."
      }

  The adapter feeds `validation_id` to
  `Kernel.uninstallValidation(...)` as `vId`, and rebuilds the
  permission plugin from `blob` via
  `deserializePermissionAccount(...)`. Phoenix never opens the
  blob.
  """
  @spec permission_dispatch_block(Delegation.t()) :: map() | nil
  def permission_dispatch_block(%Delegation{} = d) do
    if Delegation.cryptographically_revocable?(d) do
      %{
        blob: blob_to_string(d.permission_blob),
        permission_id: encode_hex(d.permission_id),
        validation_id: encode_hex(d.validation_id),
        kernel_version: d.kernel_version,
        package_version: d.permission_package_version,
        session_signer_address: d.session_signer_address
      }
    end
  end

  # --- Private helpers ----------------------------------------------------

  # Prefer the on-chain transaction hash (`hash`) when present; fall back to
  # the AA UserOperation hash (`userop_hash`) for pre-inclusion callbacks
  # (`broadcast`, `confirmation_failed`). The delegation table only keeps a
  # single identifier, so this gives us the strongest available anchor at
  # each lifecycle step. Full tx_refs (including both hashes, bundler, and
  # nonce) remain in the audit trail.
  defp extract_tx_hash(%{"tx_refs" => refs}) when is_list(refs) do
    Enum.find_value(refs, fn
      %{"hash" => hash} when is_binary(hash) -> hash
      %{"userop_hash" => userop} when is_binary(userop) -> userop
      _ -> nil
    end)
  end

  defp extract_tx_hash(_), do: nil

  # Decode a `params["permission"]` map from a `granted` callback into
  # a map of attrs that can be passed straight to `grant/3` or
  # `Delegation.changeset/2`. Missing fields stay missing — the
  # changeset accepts NULLs so an adapter that hasn't been upgraded
  # yet still produces a usable row (it just won't be
  # cryptographically revocable).
  #
  # Hex strings (`permission_id`, `validation_id`) are decoded to
  # binary at the boundary so the changeset's byte-size validation
  # has something to check. The blob is stored verbatim as bytes —
  # Phoenix never opens it. Block number is coerced from the JSON
  # number to integer so a hand-written fixture sending a string
  # falls into the changeset's normal cast path.
  defp decode_permission_artifacts(nil), do: %{}

  defp decode_permission_artifacts(%{} = perm) do
    %{}
    |> maybe_put(:permission_blob, Map.get(perm, "blob"))
    |> maybe_put(:permission_id, decode_hex(Map.get(perm, "permission_id")))
    |> maybe_put(:validation_id, decode_hex(Map.get(perm, "validation_id")))
    |> maybe_put(:kernel_version, Map.get(perm, "kernel_version"))
    |> maybe_put(:permission_package_version, Map.get(perm, "package_version"))
    |> maybe_put(:installed_at_block, Map.get(perm, "installed_at_block"))
    |> maybe_put(:install_tx_hash, Map.get(perm, "install_tx_hash"))
    |> maybe_put(:session_signer_address, Map.get(perm, "session_signer_address"))
  end

  defp decode_permission_artifacts(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp decode_hex(nil), do: nil

  defp decode_hex("0x" <> rest) do
    case Base.decode16(rest, case: :mixed) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end

  defp decode_hex(_), do: nil

  defp encode_hex(nil), do: nil
  defp encode_hex(bin) when is_binary(bin), do: "0x" <> Base.encode16(bin, case: :lower)

  # The blob arrives over the wire as a base64 string. We stored it as
  # bytes (the UTF-8 bytes of that ASCII base64 string) and write it
  # back out verbatim. If a caller passes nil or a non-binary, we
  # deliberately return nil so JSON encoding sees a missing key
  # rather than a malformed value.
  defp blob_to_string(nil), do: nil
  defp blob_to_string(bin) when is_binary(bin), do: bin
  defp blob_to_string(_), do: nil
end
