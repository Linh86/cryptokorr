defmodule Bank.SessionPermissions.BrowserInstall do
  @moduledoc """
  Browser-signed install attestation context (#474).

  Replaces the legacy server-signed install path
  (`Bank.SessionPermissions.request_install/2`) for new bindings:
  the user's connected EOA wallet signs the install
  UserOperation directly via the ZeroDev SDK in the browser, the
  browser submits to the bundler directly, and Phoenix marks the
  delegation `:active` only after **on-chain verification** of
  the installed permission validator.

  Three call sites:

    * `build_envelope/2` — what the install controller returns
      to the browser. Phoenix is the canonical source of the
      scope JSON and the smart-account address; the browser
      relays them byte-for-byte to the ZeroDev SDK.
    * `record_attestation/3` — the browser reports each step
      (`submitted` → `confirmed`, or any failure category). On
      `submitted` we persist a `:pending` delegation row keyed
      by `(binding_id, install_userop_hash)`; on `confirmed` we
      enqueue `Bank.Runtime.Workers.VerifyInstallOnchain`. On
      any failure we audit `delegation.install_failed` with a
      category atom from a fixed allowlist.
    * `status/2` — the browser polls for the install state
      (operator UI re-renders without round-tripping through
      WebSocket events).

  ## Security invariants (design § 10)

    * **Base Sepolia only** — both the envelope endpoint and
      `record_attestation/3` refuse non-`84532` bindings closed.
    * **Phoenix verifies on-chain state before active** — a
      `confirmed` attestation only enqueues the verifier worker;
      it does NOT itself flip the row to `:active`. The worker
      is the sole writer of the `:active` transition.
    * **No server / operator key is consulted on this path** —
      `Bank.SessionPermissions.BrowserInstall` does not call
      `Bank.AdapterClient.dispatch_grant_delegation/2`.
    * **Reason categories are a fixed allowlist** — any
      attestation whose `:reason` is outside
      `failure_categories/0` is collapsed to `:unknown`. Free-form
      upstream strings never reach the audit row or the
      delegation's `last_reason` column.

  ## Backwards compatibility

  Browser-signed delegations carry `root_validator_owner: "user"`;
  legacy operator-signed delegations carry `"operator"` (one-shot
  backfill in the migration). The revoke worker (#475) branches
  on this column to keep the cryptographic-revoke path live for
  legacy rows and the sentinel-revoke path for browser-signed
  rows.
  """

  import Ecto.Query

  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Runtime.Workers.PollInstallReceipt
  alias Bank.Runtime.Workers.VerifyInstallOnchain
  alias Bank.Security
  alias Bank.SessionPermissions
  alias Bank.SessionPermissions.Scope
  alias Bank.WalletBindings.WalletBinding
  alias Bank.Workspaces.Workspace

  @entry_point_v07 "0x0000000071727De22E5E9d8BAf0edAc6f37da032"

  @failure_categories ~w(
    user_rejected
    bundler_rejected
    bundler_unavailable
    bundler_not_configured
    chain_id_mismatch
    insufficient_funds
    userop_reverted
    attestation_timeout
    wallet_not_connected
    account_mismatch
    kernel_account_collision
    session_signer_unavailable
    session_signer_refused
    unknown
  )a

  @attestation_statuses ~w(
    submitted
    confirmed
    user_rejected
    bundler_rejected
    reverted
  )a

  @typedoc """
  Refusal returned when the binding cannot be installed against —
  same vocabulary `Bank.SessionPermissions.request_install/2`
  exposes for the legacy server-signed path so operators get a
  consistent error surface across both flows.
  """
  @type refusal ::
          :workspace_mismatch
          | :binding_not_verified
          | :binding_revoked
          | :unsupported_chain
          | :runtime_paused
          | :workspace_paused
          | :rpc_not_configured
          | :kernel_account_collision
          | {:invalid_attestation, atom()}
          | {:invalid_status, String.t()}
          | {:invalid_reason, atom()}
          | {:duplicate_install, String.t()}
          | term()

  @typedoc """
  The install envelope shape Phoenix returns to the browser.
  """
  @type envelope :: %{
          binding_id: String.t(),
          workspace_id: String.t(),
          smart_account_id: String.t(),
          chain_id: pos_integer(),
          entry_point_address: String.t(),
          kernel_version: String.t(),
          permissions_package_version: String.t(),
          session_signer_address: String.t() | nil,
          scope: map(),
          scope_hash: String.t(),
          bundler_rpc_url: String.t() | nil,
          chain_rpc_url: String.t() | nil,
          kernel_account_index: non_neg_integer(),
          human_readable_summary: String.t()
        }

  @doc """
  Returns the canonical fixed allowlist of failure-category
  atoms. Pinned by tests so a future regression cannot smuggle
  free-form upstream strings into the audit row.
  """
  @spec failure_categories() :: [atom()]
  def failure_categories, do: @failure_categories

  @doc """
  Returns the canonical fixed allowlist of attestation status
  strings the browser can report.
  """
  @spec attestation_statuses() :: [atom()]
  def attestation_statuses, do: @attestation_statuses

  # --- envelope ----------------------------------------------------------

  @doc """
  Build the install envelope Phoenix returns to the browser.

  Validates the binding (workspace, verified, not revoked, chain),
  computes the canonical scope JSON + SHA-256 `scope_hash`,
  audits `delegation.install_envelope_issued`, and returns the
  envelope map.

  Returns `{:error, refusal()}` for any binding-state /
  workspace / chain failure.
  """
  @spec build_envelope(Ecto.UUID.t(), WalletBinding.t()) ::
          {:ok, envelope()} | {:error, refusal()}
  def build_envelope(workspace_id, %WalletBinding{} = binding) do
    with :ok <- check_binding(workspace_id, binding),
         :ok <- check_kernel_index_collision(binding) do
      scope = Scope.default()
      scope_hash = scope_hash(scope)
      smart_account_id = SessionPermissions.compute_smart_account_id(binding)

      envelope = %{
        binding_id: binding.id,
        workspace_id: workspace_id,
        smart_account_id: smart_account_id,
        chain_id: binding.chain_id,
        entry_point_address: @entry_point_v07,
        kernel_version: Map.get(scope, "kernel_version") || Map.get(scope, :kernel_version),
        permissions_package_version: permissions_package_version(),
        session_signer_address: configured_session_signer_address(),
        scope: scope,
        scope_hash: scope_hash,
        bundler_rpc_url: bundler_rpc_url(),
        chain_rpc_url: chain_rpc_url(),
        kernel_account_index: kernel_account_index(),
        human_readable_summary: human_readable_summary(scope)
      }

      Audit.append_event(Events.delegation_install_envelope_issued(envelope))

      {:ok, envelope}
    end
  end

  @doc """
  Kernel-account collision preflight.

  Refuses to issue an install envelope when the connected user EOA
  equals `OPERATOR_ADDRESS` AND the browser's
  `:kernel_account_index` equals the operator's
  `:operator_kernel_account_index`. Without this check, the SDK
  derives the SAME smart-account address as the already-deployed
  operator account, and the install UserOp reverts on chain with
  `AA23 reverted 0x756688fe` (Kernel's `InvalidSignature()`)
  because the existing account state doesn't accept a fresh enable
  signature.

  The fix is structural: operator runs runtime UserOps on index 0,
  browser users install on index 1+. When both happen to land on
  the same EOA (the demo wallet imports `OPERATOR_PRIVATE_KEY`)
  the indices MUST differ. If they match, this returns
  `{:error, :kernel_account_collision}` which the controller
  surfaces to the JS hook as the wire-allowlisted reason atom
  `:kernel_account_collision`.
  """
  @spec check_kernel_index_collision(WalletBinding.t()) ::
          :ok | {:error, :kernel_account_collision}
  def check_kernel_index_collision(%WalletBinding{address: user_eoa}) do
    operator_eoa = operator_eoa_address()

    cond do
      is_nil(operator_eoa) ->
        # No operator EOA configured (e.g. tests / pre-prod). No
        # collision possible because we can't even derive the
        # operator's smart account.
        :ok

      not is_binary(user_eoa) ->
        :ok

      String.downcase(user_eoa) != String.downcase(operator_eoa) ->
        # Different EOA → different derived smart account → no
        # collision regardless of index choice.
        :ok

      kernel_account_index() == operator_kernel_account_index() ->
        # Same EOA AND same index → derived smart account is the
        # operator's. Block.
        {:error, :kernel_account_collision}

      true ->
        :ok
    end
  end

  # --- attestation -------------------------------------------------------

  @doc """
  Record a browser-reported attestation step.

  Required keys in `params`:

    * `"status"` — one of `attestation_statuses/0` (string or
      atom).

  Status-specific required keys:

    * `submitted` — `"install_userop_hash"` (0x + hex), and the
      typed-data `permission_id` + `validation_id` the browser
      asks Phoenix to verify.
    * `confirmed` — `"install_userop_hash"`, `"tx_hash"`,
      `"block_number"`.
    * Any failure status — `"reason"` MUST be one of
      `failure_categories/0`. Anything else collapses to
      `:unknown`.

  Returns `{:ok, %{state: state, delegation: delegation_or_nil}}`
  on success, `{:error, refusal()}` on any structural / state
  error.
  """
  @spec record_attestation(Ecto.UUID.t(), WalletBinding.t(), map()) ::
          {:ok, %{state: atom(), delegation: Delegation.t() | nil}} | {:error, refusal()}
  def record_attestation(workspace_id, %WalletBinding{} = binding, params)
      when is_binary(workspace_id) and is_map(params) do
    with :ok <- check_binding(workspace_id, binding),
         {:ok, status} <- parse_status(params) do
      do_record(status, workspace_id, binding, params)
    end
  end

  defp do_record(:submitted, workspace_id, binding, params) do
    with {:ok, userop_hash} <-
           fetch_hex(params, "install_userop_hash", :install_userop_hash_invalid),
         {:ok, permission_id_bytes} <-
           fetch_byte_string(params, "permission_id", 4, :permission_id_invalid),
         {:ok, validation_id_bytes} <-
           fetch_byte_string(params, "validation_id", 21, :validation_id_invalid) do
      smart_account_id = SessionPermissions.compute_smart_account_id(binding)

      # Real EVM smart-account address the SDK derived from
      # `(user_eoa, kernel_account_index, sudo+permission plugin
      # config)`. Phoenix stores the synthetic `smart_account_id`
      # (`sa_wb_<binding_id>`) as its DB key for backward
      # compatibility with the adapter callback wiring, but the
      # REAL address goes into `scope` so runtime dispatch
      # eventually keys on the on-chain account rather than the
      # synthetic id. Lowercased for canonical comparison; nil-safe
      # for legacy attestations that pre-date the field.
      smart_account_address =
        case Map.get(params, "smart_account_address") do
          addr when is_binary(addr) -> String.downcase(addr)
          _ -> nil
        end

      scope =
        case smart_account_address do
          nil -> Scope.default()
          addr -> Map.put(Scope.default(), "smart_account_address", addr)
        end

      result =
        Repo.transaction(fn ->
          case existing_install_row(binding.id, userop_hash) do
            %Delegation{} = existing ->
              {:idempotent, existing}

            nil ->
              attrs = %{
                smart_account_id: smart_account_id,
                # Adapter callbacks key on `delegation_id`; for the
                # browser-signed path we use the userop hash so post-hoc
                # lookup is possible without inventing a separate id.
                delegation_id: userop_hash,
                state: :pending,
                chain: chain_label(binding.chain_id),
                scope: scope,
                workspace_id: workspace_id,
                root_validator_owner: "user",
                binding_id: binding.id,
                install_userop_hash: userop_hash,
                permission_id: permission_id_bytes,
                validation_id: validation_id_bytes,
                kernel_version: Map.get(Scope.default(), :kernel_version),
                permission_package_version: permissions_package_version(),
                session_signer_address: configured_session_signer_address()
              }

              with {:ok, delegation} <-
                     %Delegation{}
                     |> Delegation.changeset(attrs)
                     |> Repo.insert(),
                   :ok <- enqueue_poller(delegation, workspace_id) do
                {:inserted, delegation}
              else
                {:error, %Ecto.Changeset{} = changeset} ->
                  Repo.rollback({:invalid_attestation, changeset_reason(changeset)})

                {:error, reason} ->
                  Repo.rollback({:invalid_attestation, reason})
              end
          end
        end)

      case result do
        {:ok, {tag, delegation}} when tag in [:idempotent, :inserted] ->
          if tag == :inserted do
            Audit.append_event(Events.delegation_install_signed_by_user(delegation))
          end

          {:ok, %{state: :submitted, delegation: delegation}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_record(:confirmed, workspace_id, binding, params) do
    with {:ok, userop_hash} <-
           fetch_hex(params, "install_userop_hash", :install_userop_hash_invalid),
         {:ok, tx_hash} <- fetch_hex(params, "tx_hash", :tx_hash_invalid),
         {:ok, block_number} <- fetch_pos_integer(params, "block_number", :block_number_invalid),
         {:ok, delegation} <- load_pending_install(binding.id, userop_hash) do
      receipt = %{tx_hash: tx_hash, block_number: block_number}

      Audit.append_event(Events.delegation_install_broadcast(delegation, receipt))

      {:ok, _job} =
        VerifyInstallOnchain.new(%{
          "delegation_id" => delegation.id,
          "binding_id" => binding.id,
          "workspace_id" => workspace_id,
          "tx_hash" => tx_hash,
          "block_number" => block_number
        })
        |> Oban.insert()

      {:ok, %{state: :verifying, delegation: delegation}}
    end
  end

  defp do_record(failure_status, workspace_id, binding, params)
       when failure_status in [:user_rejected, :bundler_rejected, :reverted] do
    reason = sanitize_reason(params, failure_status)
    userop_hash = Map.get(params, "install_userop_hash")
    smart_account_id = SessionPermissions.compute_smart_account_id(binding)

    delegation =
      case userop_hash do
        nil -> nil
        hex when is_binary(hex) -> existing_install_row(binding.id, String.downcase(hex))
      end

    case delegation do
      %Delegation{} = row ->
        {:ok, transitioned} = mark_install_failed(row, reason)

        Audit.append_event(
          Events.delegation_install_failed(%{
            binding_id: binding.id,
            delegation_id: transitioned.id,
            smart_account_id: transitioned.smart_account_id,
            install_userop_hash: transitioned.install_userop_hash,
            workspace_id: workspace_id,
            reason: reason,
            subject_type: "delegation",
            subject_id: transitioned.id
          })
        )

        {:ok, %{state: :failed, delegation: transitioned}}

      nil ->
        Audit.append_event(
          Events.delegation_install_failed(%{
            binding_id: binding.id,
            smart_account_id: smart_account_id,
            workspace_id: workspace_id,
            reason: reason
          })
        )

        {:ok, %{state: :failed, delegation: nil}}
    end
  end

  # --- status ------------------------------------------------------------

  @doc """
  Returns the latest install state for `binding` from the
  operator's perspective. The browser polls this to drive the UI
  through `awaiting → submitted → verifying → active | failed`.
  """
  @spec status(Ecto.UUID.t(), WalletBinding.t()) :: %{
          state: atom(),
          delegation: Delegation.t() | nil
        }
  def status(workspace_id, %WalletBinding{} = binding) do
    case latest_install_row(binding.id) do
      nil ->
        case check_binding(workspace_id, binding) do
          :ok -> %{state: :awaiting, delegation: nil}
          {:error, _refusal} -> %{state: :awaiting, delegation: nil}
        end

      %Delegation{state: :active} = d ->
        %{state: :active, delegation: d}

      %Delegation{state: :install_failed} = d ->
        %{state: :failed, delegation: d}

      %Delegation{state: :pending} = d ->
        # We only have a pending row after the browser successfully
        # reported `submitted` (the row's existence is the signal).
        # `confirmed` enqueues VerifyInstallOnchain but does not flip
        # the row state until the worker writes — so until then the
        # state surface is `:verifying`.
        cond do
          d.installed_at_block != nil -> %{state: :verifying, delegation: d}
          d.install_tx_hash != nil -> %{state: :verifying, delegation: d}
          true -> %{state: :submitted, delegation: d}
        end

      %Delegation{} = d ->
        %{state: d.state, delegation: d}
    end
  end

  # --- internals ---------------------------------------------------------

  @doc false
  @spec scope_hash(map()) :: String.t()
  def scope_hash(scope) when is_map(scope) do
    canonical = Jason.encode!(scope)
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
  end

  @doc false
  @spec mark_install_failed(Delegation.t(), atom()) :: {:ok, Delegation.t()} | {:error, term()}
  def mark_install_failed(%Delegation{} = delegation, reason) when is_atom(reason) do
    delegation
    |> Delegation.changeset(%{
      state: :install_failed,
      last_reason: "install_failed:" <> Atom.to_string(reason)
    })
    |> Repo.update()
  end

  defp check_binding(workspace_id, %WalletBinding{} = binding) do
    cond do
      binding.workspace_id != workspace_id ->
        {:error, :workspace_mismatch}

      binding.revoked_at != nil ->
        {:error, :binding_revoked}

      binding.verified_at == nil ->
        {:error, :binding_not_verified}

      binding.chain_id != Scope.chain_id() ->
        {:error, :unsupported_chain}

      true ->
        with :ok <- check_runtime_unpaused(),
             :ok <- check_workspace_unpaused(workspace_id) do
          :ok
        end
    end
  end

  defp check_runtime_unpaused do
    if Security.paused?(:global), do: {:error, :runtime_paused}, else: :ok
  end

  defp check_workspace_unpaused(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{} = ws ->
        if Workspace.agent_keys_paused?(ws),
          do: {:error, :workspace_paused},
          else: :ok

      nil ->
        # Treat a missing workspace as a not-found refusal — we
        # never reach `do_record/4` from a controller without a
        # session-scoped `workspace_id`, but tests can call the
        # context directly.
        {:error, :workspace_mismatch}
    end
  end

  defp parse_status(params) do
    raw = Map.get(params, "status") || Map.get(params, :status)
    string = if is_atom(raw), do: Atom.to_string(raw), else: raw

    case string do
      s when is_binary(s) ->
        atom = String.to_atom(s)
        if atom in @attestation_statuses, do: {:ok, atom}, else: {:error, {:invalid_status, s}}

      _ ->
        {:error, {:invalid_status, "<missing>"}}
    end
  end

  defp fetch_hex(params, key, error_atom) do
    case Map.get(params, key) do
      hex when is_binary(hex) ->
        normalized = String.downcase(hex)

        if String.match?(normalized, ~r/^0x[0-9a-f]+$/) do
          {:ok, normalized}
        else
          {:error, {:invalid_attestation, error_atom}}
        end

      _ ->
        {:error, {:invalid_attestation, error_atom}}
    end
  end

  defp fetch_byte_string(params, key, expected_bytes, error_atom) do
    case Map.get(params, key) do
      "0x" <> hex when is_binary(hex) ->
        with {:ok, bytes} <- Base.decode16(hex, case: :mixed) do
          if byte_size(bytes) == expected_bytes do
            {:ok, bytes}
          else
            {:error, {:invalid_attestation, error_atom}}
          end
        else
          _ -> {:error, {:invalid_attestation, error_atom}}
        end

      _ ->
        {:error, {:invalid_attestation, error_atom}}
    end
  end

  defp fetch_pos_integer(params, key, error_atom) do
    case Map.get(params, key) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_attestation, error_atom}}
    end
  end

  defp sanitize_reason(params, default_status) do
    raw = Map.get(params, "reason") || Map.get(params, :reason)

    candidate =
      cond do
        is_atom(raw) -> raw
        is_binary(raw) -> safe_atom(raw)
        true -> nil
      end

    cond do
      candidate in @failure_categories -> candidate
      default_status == :reverted -> :userop_reverted
      default_status == :bundler_rejected -> :bundler_rejected
      default_status == :user_rejected -> :user_rejected
      true -> :unknown
    end
  end

  defp safe_atom(string) when is_binary(string) do
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError -> nil
    end
  end

  defp existing_install_row(binding_id, userop_hash) do
    Repo.one(
      from d in Delegation,
        where: d.binding_id == ^binding_id and d.install_userop_hash == ^userop_hash
    )
  end

  defp load_pending_install(binding_id, userop_hash) do
    case existing_install_row(binding_id, userop_hash) do
      nil -> {:error, {:invalid_attestation, :no_pending_install}}
      %Delegation{state: :pending} = d -> {:ok, d}
      %Delegation{state: state} -> {:error, {:invalid_attestation, {:wrong_state, state}}}
    end
  end

  defp latest_install_row(binding_id) do
    Repo.one(
      from d in Delegation,
        where: d.binding_id == ^binding_id,
        order_by: [desc: d.inserted_at],
        limit: 1
    )
  end

  defp permissions_package_version, do: "5.6.3"

  defp bundler_rpc_url do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:bundler_rpc_url)
  end

  # Generic chain RPC URL used by the browser-side ZeroDev SDK for
  # the read-only `publicClient` (which calls `eth_call` against
  # EntryPoint v0.7 to compute `getSenderAddress`). Distinct from
  # `bundler_rpc_url` — see config/dev.exs for the full rationale.
  defp chain_rpc_url do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:chain_rpc_url)
  end

  @doc """
  Configured operator session-signer EOA address (the EOA the
  adapter's `DELEGATION_SIGNER_KEY` derives to). Phoenix embeds
  this into install envelopes; the browser hook displays it for
  consistency checking and the proxy sign-userop-hash endpoint
  uses it to refuse stale browser sessions that point at a
  different signer.
  """
  @spec configured_session_signer_address() :: String.t() | nil
  def configured_session_signer_address do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:session_signer_address)
  end

  # The ZeroDev Kernel CREATE2 deterministic-deploy salt for the
  # BROWSER user smart-account derivation. Defaults to 1 in dev
  # (config/dev.exs) so it doesn't collide with the operator's
  # index 0. Override per workspace via
  # `BROWSER_KERNEL_ACCOUNT_INDEX`.
  @spec kernel_account_index() :: non_neg_integer()
  def kernel_account_index do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:kernel_account_index, 1)
    |> coerce_index!()
  end

  # The Kernel index the chain_adapter uses for the operator's
  # runtime UserOps. Read from `KERNEL_ACCOUNT_INDEX` (default 0
  # in dev). Phoenix uses this ONLY for collision detection —
  # the actual index the adapter passes to `createKernelAccount`
  # lives in `chain_adapter/src/...`.
  @spec operator_kernel_account_index() :: non_neg_integer()
  def operator_kernel_account_index do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:operator_kernel_account_index, 0)
    |> coerce_index!()
  end

  # The chain_adapter's operator EOA — the one whose private key
  # signs runtime UserOps. Phoenix never holds the key; it reads
  # the address only for the kernel-index-collision preflight.
  @spec operator_eoa_address() :: String.t() | nil
  def operator_eoa_address do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:operator_eoa_address)
  end

  # Indices arrive as integers from config OR as `"0"`/`"1"` strings
  # when set straight from an env var. Coerce defensively so a
  # mis-shaped config raises at boot rather than at install time.
  defp coerce_index!(n) when is_integer(n) and n >= 0, do: n
  defp coerce_index!(s) when is_binary(s), do: String.to_integer(s)

  defp human_readable_summary(_scope) do
    "USDC transfer · 0x swap · allowlisted Morpho USDC deposit"
  end

  defp chain_label(84_532), do: "base-sepolia"
  defp chain_label(8453), do: "base"
  defp chain_label(_), do: "unknown"

  defp changeset_reason(%Ecto.Changeset{errors: errors}) do
    case errors do
      [{field, _} | _] -> field
      _ -> :invalid
    end
  end

  # Enqueue the bundler-receipt poller so a tab-close after
  # `submitted` still reaches a verdict (#500). The poller is the
  # safety net; the browser's `confirmed` POST is the fast-path
  # optimisation. Both routes converge on `VerifyInstallOnchain`
  # which dedupes by `delegation_id`. Returns `:ok` on
  # `{:ok, _job}` from `Oban.insert/1`; any insertion failure
  # surfaces as `{:error, reason}` so the caller can roll back the
  # row insert (a `:pending` row without a poller is exactly the
  # tab-close hazard #500 fixes).
  defp enqueue_poller(%Delegation{} = delegation, workspace_id) do
    args = %{
      "delegation_id" => delegation.id,
      "binding_id" => delegation.binding_id,
      "workspace_id" => workspace_id,
      "install_userop_hash" => delegation.install_userop_hash,
      "bundler_rpc_url" => bundler_rpc_url(),
      "deadline_at" => PollInstallReceipt.deadline_at_iso()
    }

    case args |> PollInstallReceipt.new() |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
