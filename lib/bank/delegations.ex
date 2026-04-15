defmodule Bank.Delegations do
  @moduledoc """
  Control-plane model of smart-account delegation state.

  The authoritative delegation lives on-chain, and the mechanics of
  granting, signing, and revoking happen in the TypeScript adapter
  (see `docs/bank-v0.1-runtime-flow-and-api.md §3`). This module is
  the Phoenix-side projection of that state: just enough information
  for routing, policy evaluation, and the operator dashboard to
  answer three questions without making an adapter round-trip:

    1. Does this smart account currently have an active delegation?
    2. Is a revoke in flight? (affects execution gating)
    3. When does the delegation window expire? (for approval TTL
       interplay)

  ## State machine

      none ──grant──▶ active ──revoke_requested──▶ revoking
                        │                             │
                        │                             └──revoked───▶ revoked
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

  v0.1 keeps state in-memory (same pattern as `Bank.Security.PauseState`).
  The adapter is the source of truth on chain; this GenServer is a
  warm cache that survives within one Phoenix node. On restart,
  operators either wait for the adapter's next delegation-state push
  or re-query. A persisted projection is a v1.0 follow-up tracked in
  the runtime-flow doc.

  ## Public API

      grant(smart_account_id, attrs)
      record_revoke_requested(smart_account_id, attrs)
      record_revoked(smart_account_id, attrs)
      record_expired(smart_account_id)
      get(smart_account_id)
      executable?(smart_account_id)
      reset()

  `attrs` accepts `:counterparty_id`, `:scope`, `:expires_at`,
  `:granted_at`, `:reason`. Callers that don't know a field can omit
  it.
  """

  use GenServer

  @type state :: :active | :revoking | :revoked | :expired
  @type smart_account_id :: String.t()
  @type record :: %{
          state: state(),
          counterparty_id: String.t() | nil,
          scope: map() | nil,
          granted_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          revoke_requested_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          last_reason: atom() | String.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Register a fresh delegation. If one already exists for the smart
  account, the grant replaces it — callers that care about the
  previous state (e.g. auditing a re-grant after a revoke) should
  read first.
  """
  @spec grant(smart_account_id(), keyword() | map()) :: {:ok, record()}
  def grant(smart_account_id, attrs \\ []) when is_binary(smart_account_id) do
    GenServer.call(__MODULE__, {:grant, smart_account_id, to_map(attrs)})
  end

  @doc """
  Mark a delegation as revoke-requested. From this moment the
  smart account is non-executable, even if the chain hasn't
  confirmed — the intent to revoke is the commitment.

  Returns `{:ok, record}` or `{:error, :not_found}`.
  """
  @spec record_revoke_requested(smart_account_id(), keyword() | map()) ::
          {:ok, record()} | {:error, :not_found}
  def record_revoke_requested(smart_account_id, attrs \\ []) do
    GenServer.call(__MODULE__, {:revoke_requested, smart_account_id, to_map(attrs)})
  end

  @doc "Mark a delegation as confirmed-revoked on-chain."
  @spec record_revoked(smart_account_id(), keyword() | map()) ::
          {:ok, record()} | {:error, :not_found}
  def record_revoked(smart_account_id, attrs \\ []) do
    GenServer.call(__MODULE__, {:revoked, smart_account_id, to_map(attrs)})
  end

  @doc "Mark a delegation as expired (window closed without use or re-grant)."
  @spec record_expired(smart_account_id()) :: {:ok, record()} | {:error, :not_found}
  def record_expired(smart_account_id) do
    GenServer.call(__MODULE__, {:expired, smart_account_id})
  end

  @doc "Fetch the current delegation record, if any."
  @spec get(smart_account_id()) :: record() | nil
  def get(smart_account_id) do
    GenServer.call(__MODULE__, {:get, smart_account_id})
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
      %{state: :active, expires_at: nil} -> true
      %{state: :active, expires_at: %DateTime{} = exp} -> DateTime.compare(exp, now) == :gt
      _ -> false
    end
  end

  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # --- callbacks ----------------------------------------------------

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:grant, id, attrs}, _from, state) do
    record = %{
      state: :active,
      counterparty_id: Map.get(attrs, :counterparty_id),
      scope: Map.get(attrs, :scope),
      granted_at: Map.get(attrs, :granted_at, DateTime.utc_now()),
      expires_at: Map.get(attrs, :expires_at),
      revoke_requested_at: nil,
      revoked_at: nil,
      last_reason: Map.get(attrs, :reason)
    }

    {:reply, {:ok, record}, Map.put(state, id, record)}
  end

  def handle_call({:revoke_requested, id, attrs}, _from, state) do
    case Map.get(state, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      existing ->
        updated = %{
          existing
          | state: :revoking,
            revoke_requested_at: Map.get(attrs, :revoke_requested_at, DateTime.utc_now()),
            last_reason: Map.get(attrs, :reason, existing.last_reason)
        }

        {:reply, {:ok, updated}, Map.put(state, id, updated)}
    end
  end

  def handle_call({:revoked, id, attrs}, _from, state) do
    case Map.get(state, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      existing ->
        updated = %{
          existing
          | state: :revoked,
            revoked_at: Map.get(attrs, :revoked_at, DateTime.utc_now()),
            last_reason: Map.get(attrs, :reason, existing.last_reason)
        }

        {:reply, {:ok, updated}, Map.put(state, id, updated)}
    end
  end

  def handle_call({:expired, id}, _from, state) do
    case Map.get(state, id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      existing ->
        {:reply, {:ok, %{existing | state: :expired}},
         Map.put(state, id, %{existing | state: :expired})}
    end
  end

  def handle_call({:get, id}, _from, state), do: {:reply, Map.get(state, id), state}

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  defp to_map(attrs) when is_map(attrs), do: attrs
  defp to_map(attrs) when is_list(attrs), do: Map.new(attrs)
end
