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
  owns its meaning. After GitHub #58 ships against a Kernel v3
  smart account, fresh `delegation_id` values are the lowercase
  hex form of the Permission Validator's `bytes32 permissionId`
  (`0x` + 64 lowercase hex digits, 66 characters total). The
  cryptographic revoke is then a single ERC-7579 `execute(...)`
  call against that validator using that id; everything Phoenix
  observes — `:revoking → :revoked`, the `tx_refs` carried in the
  callback, the audit chain — is unchanged from the v0.1 sentinel
  path.

  The decision behind that mapping lives in
  `docs/smart-account-and-revoke-design.md` (#56); the adapter-side
  ABI fragment, mapping helpers, and tripwire test landed under
  GitHub #57. Pre-Kernel grants continue to use the v0.1 `del_…`
  placeholder shape and remain stuck on the sentinel revoke until
  the smart account is migrated.

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
  """

  import Ecto.Query

  alias Bank.Delegations.Delegation
  alias Bank.Repo

  @type smart_account_id :: String.t()

  # --- Read API -----------------------------------------------------------

  @doc """
  List all non-terminal delegations across all smart accounts.
  Returns a list of `Delegation` structs ordered by most recently created.
  """
  @spec list_active() :: [Delegation.t()]
  def list_active do
    Repo.all(
      from(d in Delegation,
        where: d.state in [:pending, :active, :revoking, :revoke_failed],
        order_by: [desc: d.inserted_at]
      )
    )
  end

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

  Returns `{:ok, delegation}` or `{:error, :not_found}`.
  """
  @spec record_revoke_requested(smart_account_id(), map()) ::
          {:ok, Delegation.t()} | {:error, :not_found | :invalid_transition}
  def record_revoke_requested(smart_account_id, attrs \\ %{}) do
    case get(smart_account_id) do
      nil ->
        {:error, :not_found}

      %Delegation{state: state} = delegation
      when state in [:active, :pending, :revoke_failed] ->
        delegation
        |> Delegation.revoke_requested_changeset(attrs)
        |> Repo.update()

      %Delegation{} ->
        {:error, :invalid_transition}
    end
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
    case get(smart_account_id) do
      nil ->
        {:error, :not_found}

      %Delegation{state: :revoking} = delegation ->
        delegation
        |> Delegation.revoke_failed_changeset(attrs)
        |> Repo.update()

      %Delegation{} ->
        {:error, :invalid_transition}
    end
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
    case get(smart_account_id) do
      nil ->
        {:error, :not_found}

      %Delegation{state: :revoking} = delegation ->
        delegation
        |> Delegation.revoked_changeset(attrs)
        |> Repo.update()

      %Delegation{} ->
        {:error, :invalid_transition}
    end
  end

  @doc "Mark a delegation as expired."
  @spec record_expired(smart_account_id()) ::
          {:ok, Delegation.t()} | {:error, :not_found | :invalid_transition}
  def record_expired(smart_account_id) do
    case get(smart_account_id) do
      nil ->
        {:error, :not_found}

      %Delegation{state: :active} = delegation ->
        delegation
        |> Delegation.expired_changeset()
        |> Repo.update()

      %Delegation{} ->
        {:error, :invalid_transition}
    end
  end

  @doc """
  Apply a `delegation.state_changed` callback from the adapter.

  Maps adapter states to context transitions:
    - "granted" → grant (upsert: creates if not found)
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
        case get(smart_account_id) do
          nil ->
            grant(smart_account_id, delegation_id, %{
              last_reason: reason,
              scope: Map.get(params, "scope", %{})
            })

          %Delegation{state: :pending} = delegation ->
            delegation
            |> Delegation.grant_changeset(%{last_reason: reason})
            |> Repo.update()

          %Delegation{state: :active} = delegation ->
            {:ok, delegation}

          _ ->
            {:error, :invalid_transition}
        end

      "revoking" ->
        record_revoke_requested(smart_account_id, %{
          last_reason: reason
        })

      "revoke_failed" ->
        record_revoke_failed(smart_account_id, %{
          last_reason: reason,
          last_tx_hash: tx_hash
        })

      "revoked" ->
        record_revoked(smart_account_id, %{
          last_reason: reason,
          last_tx_hash: tx_hash
        })

      "expired" ->
        record_expired(smart_account_id)

      _ ->
        {:error, :unknown_state}
    end
  end

  def apply_callback(_), do: {:error, :invalid_callback}

  @doc """
  Record a browser-initiated connect request (v1.1 scaffolding).

  Writes an `intent-to-connect` audit event capturing the signed
  payload the JS hook built. The actual adapter call
  (`dispatch_grant_delegation`) is stubbed until the adapter repo
  exposes the endpoint — see `docs/wallet-connect.md` for the full
  plan.

  Accepts a map with:
    * `:smart_account_id` — string
    * `:chain_id` — integer (must be Base or Base Sepolia)
    * `:account` — string (EOA / session key address)
    * `:delegation_payload` — map (signed payload, optional during
      the v1.1 stub phase)

  Returns `{:ok, :accepted}` after the audit event is written.
  """
  @spec request_connect(map()) :: {:ok, :accepted} | {:error, term()}
  def request_connect(%{
        "smart_account_id" => sa_id,
        "chain_id" => chain_id,
        "account" => account
      })
      when is_binary(sa_id) and is_integer(chain_id) and is_binary(account) do
    with :ok <- validate_chain(chain_id),
         {:ok, _event} <- write_intent_audit(sa_id, chain_id, account) do
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
end
