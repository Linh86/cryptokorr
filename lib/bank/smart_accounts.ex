defmodule Bank.SmartAccounts do
  @moduledoc """
  Workspace-scoped smart account context (#183, epic #167).

  Public surface for the `smart_accounts` table — the first-
  class home for ERC-4337 / kernel smart accounts the runtime
  acts through. Today `delegation.smart_account_id` and
  `execution_plan.smart_account_id` are bare opaque strings;
  this context lets workspace-scoped flows resolve a smart
  account by `(workspace_id, chain, address)` triple instead of
  scanning delegation rows.

  ## Public surface

      create_smart_account(attrs)
      get_smart_account(id)
      get_in_workspace(id, workspace_id)
      list_for_workspace(workspace_id, opts \\\\ [])
      find_by_address(workspace_id, chain, address)
      set_status(smart_account, status)
      revoke(smart_account)

  ## Workspace boundary

  Every read and write helper takes a `workspace_id`. There is
  no global `get_smart_account/1` that returns rows across
  workspaces — siblings cannot observe each other's smart
  accounts even by id (`get_smart_account/1` returns the row
  but enforces nothing; callers MUST go through
  `get_in_workspace/2` for workspace-checked lookups).

  ## What this context is NOT

    * It does NOT broadcast on chain. Provisioning a row here
      is a database action; the on-chain deployment is a
      separate worker (#184/#185 deliverable).
    * It does NOT modify `delegation.smart_account_id` or
      `execution_plan.smart_account_id`. Those remain bare
      strings until #184/#185 wire the new model into the
      dispatch path.
    * It does NOT emit notifications today. Operator-facing
      lifecycle notifications (provisioning success / failure,
      revocation) wait for the UI surface in #186.

  ## Audit posture

  Lifecycle transitions emit `Bank.Audit` events through the
  existing `safe_emit/1` pattern (matches `Bank.Access` /
  `Bank.Workspaces`): `smart_account.created`,
  `smart_account.status_changed`, `smart_account.revoked`.
  Audit failures are logged + swallowed so a transient audit
  table problem cannot roll back a user-visible action.
  """

  import Ecto.Query

  alias Bank.Audit
  alias Bank.Repo
  alias Bank.SmartAccounts.SmartAccount

  require Logger

  @type uuid :: String.t()
  @type create_attrs :: %{
          required(:workspace_id) => uuid(),
          required(:chain) => String.t(),
          required(:address) => String.t(),
          optional(:status) => atom(),
          optional(:owner_user_id) => uuid() | nil,
          optional(:owner_wallet_address) => String.t() | nil,
          optional(:metadata) => map()
        }

  @type list_opt :: {:status, atom() | [atom()]} | {:chain, String.t()} | {:limit, pos_integer()}

  # --- Create -----------------------------------------------------------------

  @doc """
  Create a smart account row.

  Returns `{:ok, smart_account}` on success, `{:error, changeset}`
  on validation failure (including the unique-index race for
  `(workspace_id, chain, address)`).

  Address and `owner_wallet_address` are normalised to
  lowercased + trimmed at the changeset boundary so duplicate
  detection is reliable across operator typing.

  Emits a `smart_account.created` audit event on success.
  """
  @spec create_smart_account(map()) ::
          {:ok, SmartAccount.t()} | {:error, Ecto.Changeset.t()}
  def create_smart_account(attrs) when is_map(attrs) do
    case attrs |> SmartAccount.create_changeset() |> Repo.insert() do
      {:ok, %SmartAccount{} = smart_account} = ok ->
        safe_emit(:smart_account_created, smart_account)
        ok

      {:error, _} = err ->
        err
    end
  end

  # --- Read -------------------------------------------------------------------

  @doc """
  Fetch a smart account by id.

  Returns the struct or `nil`. Does NOT enforce a workspace
  boundary — callers acting on behalf of a workspace MUST go
  through `get_in_workspace/2` instead.
  """
  @spec get_smart_account(uuid()) :: SmartAccount.t() | nil
  def get_smart_account(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(SmartAccount, uuid)
      :error -> nil
    end
  end

  def get_smart_account(_), do: nil

  @doc """
  Workspace-scoped fetch by id.

  Returns `{:ok, smart_account}` only if the row exists AND
  belongs to `workspace_id`. Returns `{:error, :not_found}` for
  a missing row, a row that belongs to a different workspace,
  or a malformed id.

  Use this from any caller that holds a `workspace_id` —
  `get_smart_account/1` can leak across workspaces if the
  caller forgets the boundary check.
  """
  @spec get_in_workspace(uuid(), uuid()) ::
          {:ok, SmartAccount.t()} | {:error, :not_found}
  def get_in_workspace(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, _ws_uuid} <- Ecto.UUID.cast(workspace_id),
         %SmartAccount{workspace_id: ^workspace_id} = smart_account <-
           Repo.get(SmartAccount, uuid) do
      {:ok, smart_account}
    else
      _ -> {:error, :not_found}
    end
  end

  def get_in_workspace(_, _), do: {:error, :not_found}

  @doc """
  List smart accounts for a workspace.

  Default order: most recent first (`inserted_at` DESC).

  Options:

    * `:status` — atom or list of atoms; filter by lifecycle
      state. Default returns all statuses.
    * `:chain` — string; filter to one chain id.
    * `:limit` — positive integer; default 100, max 500.
  """
  @spec list_for_workspace(uuid(), [list_opt()]) :: [SmartAccount.t()]
  def list_for_workspace(workspace_id, opts \\ []) when is_binary(workspace_id) do
    limit = opts |> Keyword.get(:limit, 100) |> max(1) |> min(500)

    SmartAccount
    |> where([s], s.workspace_id == ^workspace_id)
    |> apply_status_filter(Keyword.get(opts, :status))
    |> apply_chain_filter(Keyword.get(opts, :chain))
    |> order_by([s], desc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Look up a smart account by `(workspace_id, chain, address)`.

  Address is normalised at the boundary so callers don't have
  to lowercase it. Returns the struct or `nil`.
  """
  @spec find_by_address(uuid(), String.t(), String.t()) :: SmartAccount.t() | nil
  def find_by_address(workspace_id, chain, address)
      when is_binary(workspace_id) and is_binary(chain) and is_binary(address) do
    chain_normalised = chain |> String.trim() |> String.downcase()
    address_normalised = address |> String.trim() |> String.downcase()

    Repo.one(
      from(s in SmartAccount,
        where:
          s.workspace_id == ^workspace_id and
            s.chain == ^chain_normalised and
            s.address == ^address_normalised,
        limit: 1
      )
    )
  end

  def find_by_address(_, _, _), do: nil

  # --- Lifecycle --------------------------------------------------------------

  @doc """
  Transition a smart account's status.

  Valid statuses are `:provisioning`, `:active`, `:inactive`,
  `:revoked`. Stamps `provisioned_at` on the first `:active`
  transition (only when previously unset, so re-runs do not
  move the timestamp) and `revoked_at` on `:revoked`.

  Refuses transitions out of `:revoked` (terminal). Idempotent
  no-ops (`set_status` to current status) return
  `{:ok, :unchanged, smart_account}` without an audit event so
  retries do not double-write.
  """
  @spec set_status(SmartAccount.t(), atom()) ::
          {:ok, :changed, SmartAccount.t()}
          | {:ok, :unchanged, SmartAccount.t()}
          | {:error, :terminal | Ecto.Changeset.t()}
  def set_status(%SmartAccount{} = smart_account, new_status) when is_atom(new_status) do
    cond do
      new_status == smart_account.status ->
        {:ok, :unchanged, smart_account}

      smart_account.status == :revoked ->
        {:error, :terminal}

      new_status not in SmartAccount.statuses() ->
        {:error, :invalid_status}

      true ->
        do_set_status(smart_account, new_status)
    end
  end

  defp do_set_status(%SmartAccount{} = smart_account, new_status) do
    case smart_account
         |> SmartAccount.status_changeset(new_status, DateTime.utc_now())
         |> Repo.update() do
      {:ok, %SmartAccount{} = updated} ->
        safe_emit(:smart_account_status_changed, updated, %{
          from_status: smart_account.status,
          to_status: new_status
        })

        {:ok, :changed, updated}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Revoke a smart account. Convenience wrapper around
  `set_status(_, :revoked)` so call sites don't have to know
  the enum value.

  Returns:

    * `{:ok, :changed, smart_account}` — fresh revocation; the
      row's `status` is now `:revoked` and `revoked_at` is
      stamped.
    * `{:ok, :unchanged, smart_account}` — already `:revoked`;
      idempotent no-op.
  """
  @spec revoke(SmartAccount.t()) ::
          {:ok, :changed, SmartAccount.t()}
          | {:ok, :unchanged, SmartAccount.t()}
          | {:error, Ecto.Changeset.t()}
  def revoke(%SmartAccount{} = smart_account) do
    case set_status(smart_account, :revoked) do
      {:error, :terminal} -> {:ok, :unchanged, smart_account}
      other -> other
    end
  end

  # --- Internals --------------------------------------------------------------

  defp apply_status_filter(query, nil), do: query

  defp apply_status_filter(query, status) when is_atom(status),
    do: where(query, [s], s.status == ^status)

  defp apply_status_filter(query, statuses) when is_list(statuses),
    do: where(query, [s], s.status in ^statuses)

  defp apply_chain_filter(query, nil), do: query

  defp apply_chain_filter(query, chain) when is_binary(chain) do
    chain_normalised = chain |> String.trim() |> String.downcase()
    where(query, [s], s.chain == ^chain_normalised)
  end

  # Audit emission lives behind a swallow-and-log helper that
  # matches `Bank.Access.safe_emit/1`. Audit-table outages must
  # never roll back a smart-account state transition.
  defp safe_emit(kind, smart_account, extra \\ %{}) do
    attrs = build_audit_attrs(kind, smart_account, extra)

    case Audit.append_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("Bank.SmartAccounts: audit emission failed: #{inspect(reason)}")
        :ok
    end
  end

  defp build_audit_attrs(:smart_account_created, %SmartAccount{} = sa, _extra) do
    %{
      actor: :runtime,
      event_type: "smart_account.created",
      subject_type: "smart_account",
      subject_id: sa.id,
      correlation_id: sa.id,
      after_ref: %{
        "workspace_id" => sa.workspace_id,
        "chain" => sa.chain,
        "address" => sa.address,
        "status" => Atom.to_string(sa.status)
      }
    }
  end

  defp build_audit_attrs(:smart_account_status_changed, %SmartAccount{} = sa, extra) do
    from_status = extra |> Map.get(:from_status) |> atom_to_string()
    to_status = extra |> Map.get(:to_status) |> atom_to_string()

    %{
      actor: :runtime,
      event_type: "smart_account.status_changed",
      subject_type: "smart_account",
      subject_id: sa.id,
      correlation_id: sa.id,
      before_ref: %{"status" => from_status},
      after_ref: %{
        "workspace_id" => sa.workspace_id,
        "chain" => sa.chain,
        "status" => to_status
      }
    }
  end

  defp atom_to_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_to_string(_), do: nil
end
