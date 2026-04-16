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
                           │                             └──revoked──▶ revoked
                           │
                           └──expire──▶ expired

  Transitions are monotonically cautious — any state other than
  `:active` disables autonomous execution regardless of the
  surrounding decision (see `executable?/1`). In particular:

    * `:revoking` is treated as non-executable, because the revoke
      request is a commitment to stop using this delegation even
      before the chain confirms.
    * `:expired` prevents execution from reusing a stale window.
    * `:revoked` is terminal; a new grant produces a *new* record.

  ## Persistence

  State is durable in Postgres via the `delegations` table. The
  adapter is the source of truth on chain; this context is a
  projection that survives restart.

  ## Public API

      grant(smart_account_id, delegation_id, attrs)
      record_revoke_requested(smart_account_id, attrs)
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
        where: d.state in [:pending, :active, :revoking],
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
            d.state in [:pending, :active, :revoking],
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

  Returns `{:ok, delegation}` or `{:error, :not_found}`.
  """
  @spec record_revoke_requested(smart_account_id(), map()) ::
          {:ok, Delegation.t()} | {:error, :not_found | :invalid_transition}
  def record_revoke_requested(smart_account_id, attrs \\ %{}) do
    case get(smart_account_id) do
      nil ->
        {:error, :not_found}

      %Delegation{state: state} = delegation when state in [:active, :pending] ->
        delegation
        |> Delegation.revoke_requested_changeset(attrs)
        |> Repo.update()

      %Delegation{} ->
        {:error, :invalid_transition}
    end
  end

  @doc "Mark a delegation as confirmed-revoked on-chain."
  @spec record_revoked(smart_account_id(), map()) ::
          {:ok, Delegation.t()} | {:error, :not_found | :invalid_transition}
  def record_revoked(smart_account_id, attrs \\ %{}) do
    case get(smart_account_id) do
      nil ->
        {:error, :not_found}

      %Delegation{state: state} = delegation when state in [:revoking, :active, :pending] ->
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
    - "revoked" → record_revoked
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

  # --- Private helpers ----------------------------------------------------

  defp extract_tx_hash(%{"tx_refs" => [%{"hash" => hash} | _]}), do: hash
  defp extract_tx_hash(_), do: nil
end
