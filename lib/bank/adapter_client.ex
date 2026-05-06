defmodule Bank.AdapterClient do
  @moduledoc """
  Thin HTTP client for dispatching work to the TypeScript chain adapter.

  The adapter is a separate service at `{base_url}`; Phoenix dispatches
  a transfer via `POST {base_url}/dispatch/transfer` with the
  dispatch-direction bearer secret in the `Authorization` header. On
  success the adapter returns `HTTP 202 {accepted: true,
  execution_plan_id}` and reports chain progress asynchronously via
  `POST /internal/adapter/callback` back into Phoenix.

  Transport security (TLS / mTLS) is operator-supplied via the optional
  `:req_options` keyword (see `Configuration` below); the dispatch
  client does not pin a transport on its own — `ADAPTER_BASE_URL`
  decides whether the connection runs over `http://` or `https://`.

  This module owns the three concerns of the outbound half of that
  contract:

    * Payload shaping (matches `priv/adapter/contract.md` v1).
    * Auth + timeouts.
    * A small, typed error surface callers can map onto retry or
      fail-closed semantics.

  It is intentionally narrow. There is no generic "dispatch any
  action" helper — each adapter action gets its own function so the
  request shape stays explicit at the call site.

  ## Error surface

    * `{:ok, %{accepted: true, execution_plan_id: id}}` — the adapter
      has accepted the dispatch and will report progress via callback.
    * `{:error, :adapter_unavailable}` — network/DNS/timeout. Caller
      should retry with backoff.
    * `{:error, {:adapter_rejected, status, body}}` — deterministic
      4xx rejection (validation, unsupported chain/asset). Caller
      should NOT retry.
    * `{:error, {:adapter_error, status, body}}` — 5xx. Retryable.
    * `{:error, :invalid_response}` — 2xx but response didn't match
      the expected shape. Treat as a contract bug; do not retry.
    * `{:error, {:target_not_resolvable, reason}}` — intent target
      could not be resolved to an address without operator help.

  ## Configuration

  Reads `:bank, Bank.AdapterClient` at dispatch time:

      config :bank, Bank.AdapterClient,
        base_url: "http://localhost:4100",
        # Bearer Phoenix sends on outbound /dispatch/*; the adapter
        # validates this. NOT the same secret the adapter uses on its
        # callbacks back to Phoenix — that is `:callback_secret` and is
        # consumed by `BankWeb.Plugs.VerifyAdapterAuth`.
        dispatch_secret: "dev-dispatch-secret",
        callback_secret: "dev-callback-secret",
        # Optional: extra options passed to Req (e.g. a test plug, or
        # `connect_options: [transport_opts: [...]]` for client-side
        # mTLS). Phoenix does not ship a default mTLS configuration;
        # see docs/security.md for the operator-supplied shape.
        req_options: []

  Tests override `:req_options` with `{Req.Test, Bank.AdapterClient}`
  and stub with `Req.Test.stub/2`.
  """

  require Logger

  import Ecto.Query

  alias Bank.Counterparties.AddressLabel
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  # `Bank.Decisions.SwapRouteArtifacts` is referenced via fully
  # qualified call (no compile-time alias) to avoid a circular
  # alias ordering — `Bank.Decisions` itself uses `AdapterClient`.

  @contract_version 1
  @default_timeout_ms 5_000

  @type transfer_ok :: %{accepted: true, execution_plan_id: String.t()}
  @type swap_ok :: %{accepted: true, execution_plan_id: String.t()}
  @type revoke_ok :: %{accepted: true, smart_account_id: String.t()}
  @type grant_ok :: %{accepted: true, smart_account_id: String.t()}
  @type transfer_error ::
          :adapter_unavailable
          | :invalid_response
          | {:adapter_rejected, pos_integer(), map() | String.t()}
          | {:adapter_error, pos_integer(), map() | String.t()}
          | {:target_not_resolvable, atom()}
  @type swap_error ::
          :adapter_unavailable
          | :invalid_response
          | {:adapter_rejected, pos_integer(), map() | String.t()}
          | {:adapter_error, pos_integer(), map() | String.t()}
          | {:invalid_swap_plan, atom()}
  @type revoke_error ::
          :adapter_unavailable
          | :invalid_response
          | {:adapter_rejected, pos_integer(), map() | String.t()}
          | {:adapter_error, pos_integer(), map() | String.t()}
  @type grant_error ::
          :adapter_unavailable
          | :invalid_response
          | {:adapter_rejected, pos_integer(), map() | String.t()}
          | {:adapter_error, pos_integer(), map() | String.t()}

  @doc """
  Dispatch a transfer execution plan to the adapter.

  The plan must carry `:chain`, `:asset`, `:smart_account_id`,
  `:signing_requirements`, and a valid `:intent_id`. The owning
  intent supplies the amount and target; the client resolves the
  target address from the intent's counterparty/label pointers.
  """
  @spec dispatch_transfer(ExecutionPlan.t(), keyword()) ::
          {:ok, transfer_ok()} | {:error, transfer_error()}
  def dispatch_transfer(%ExecutionPlan{} = plan, opts \\ []) do
    with {:ok, payload} <- build_transfer_payload(plan) do
      post("/dispatch/transfer", payload, :transfer, opts)
    end
  end

  @doc """
  Dispatch a swap execution plan to the adapter (#193).

  The plan must carry `:smart_account_id`, `:chain`, `:asset`,
  `:signing_requirements`, and a `:steps` payload produced by
  `Bank.Decisions.SwapRouteArtifacts.from_route/1` (#190). The
  persisted route fields (route_hash, source/destination tokens,
  spender, swap_target_contract, calldata, slippage_bps,
  quote_timestamp, deadline) are forwarded verbatim — the adapter
  is the source of truth for on-chain semantics; Phoenix only
  validates shape via `Bank.Decisions.SwapDispatchSafety.validate/3`
  before this call.
  """
  @spec dispatch_swap(ExecutionPlan.t(), keyword()) ::
          {:ok, swap_ok()} | {:error, swap_error()}
  def dispatch_swap(%ExecutionPlan{} = plan, opts \\ []) do
    with {:ok, payload} <- build_swap_payload(plan) do
      post("/dispatch/swap", payload, :swap, opts)
    end
  end

  @doc """
  Dispatch an approved Morpho ERC-4626 USDC deposit execution plan to
  the adapter (#206).

  The plan must carry `:chain == "base-sepolia"`, `:asset == "USDC"`,
  `:smart_account_id`, `:signing_requirements`, and a Morpho `:steps`
  payload built by `Bank.Decisions.MorphoDepositArtifacts`. The
  payload sent on the wire excludes calldata — the adapter builds
  ERC-4626 `deposit(assets, receiver)` and bounded `IERC20.approve`
  calldata itself from the safe primitives (vault address, amount,
  receiver). Phoenix never supplies adapter calldata, and the
  adapter never accepts caller-supplied bytes.

  Pre-dispatch safety re-checks (vault allowlist, snapshot
  freshness, material drift) are the caller's responsibility — see
  `Bank.Decisions.MorphoDispatchSafety.validate/2`. This function
  trusts that the gate has run.
  """
  @spec dispatch_morpho_deposit(ExecutionPlan.t(), keyword()) ::
          {:ok, transfer_ok()} | {:error, transfer_error()}
  def dispatch_morpho_deposit(%ExecutionPlan{} = plan, opts \\ []) do
    with {:ok, payload} <- build_morpho_deposit_payload(plan) do
      post("/dispatch/morpho_deposit", payload, :morpho_deposit, opts)
    end
  end

  @doc """
  Dispatch an on-chain delegation revoke for a smart account.

  The adapter is expected to sign and broadcast the revoke transaction
  and report progress via `delegation.state_changed` callbacks
  (`revoking` → `revoked`). The revoke is runtime-scoped and carries a
  `null` correlation id per the contract.

  Accepts a map with `:smart_account_id` (required), `:delegation_id`
  (required — opaque to Phoenix; the on-the-wire encoding is deferred
  to the ZeroDev SDK integration in
  `docs/zerodev-permissions-integration.md` and is one of: a 4-byte
  ZeroDev `permissionId`, a 21-byte Kernel `validationId`, or a
  serialized plugin blob. Pre-integration sentinel accounts continue
  to send the legacy `del_…` placeholder), `:reason` (optional;
  defaults to `"unspecified"`), and an optional `:permission` map
  carrying the serialized ZeroDev plugin and denormalized id fields
  for the cryptographic revoke path (#58).

  The `:permission` block is additive and non-breaking. When absent
  the adapter takes the sentinel path. When present the adapter
  attempts the real `Kernel.uninstallValidation(...)` UserOp and
  fails closed (`state=revoke_failed`) if it cannot honor the block
  — it never silently downgrades to sentinel.

  The wire shape, when set, is:

      %{
        blob: "<base64>",
        permission_id: "0x<8 hex>",
        validation_id: "0x<42 hex>",
        kernel_version: "0.3.1",
        package_version: "5.6.3",
        session_signer_address: "0x<40 hex>"
      }

  See `Bank.Delegations.permission_dispatch_block/1` for the
  caller-side helper that produces this map from a delegation row.
  """
  @spec dispatch_revoke_delegation(map(), keyword()) ::
          {:ok, revoke_ok()} | {:error, revoke_error()}
  def dispatch_revoke_delegation(
        %{smart_account_id: smart_account_id, delegation_id: delegation_id} = args,
        opts \\ []
      )
      when is_binary(smart_account_id) and is_binary(delegation_id) do
    base = %{
      contract_version: @contract_version,
      action: "revoke_delegation",
      smart_account_id: smart_account_id,
      delegation_id: delegation_id,
      reason: Map.get(args, :reason, "unspecified"),
      correlation_id: nil,
      emitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    payload =
      case Map.get(args, :permission) do
        %{} = block -> Map.put(base, :permission, block)
        _ -> base
      end

    post("/dispatch/revoke_delegation", payload, :revoke, opts)
  end

  @doc """
  Dispatch a delegation GRANT to the adapter (#58 grant flow).

  The adapter is expected to (1) build a real ZeroDev permission
  plugin via `toPermissionValidator(...)`, (2) install it on the
  Kernel account through a sudo-signed UserOp, (3) call
  `serializePermissionAccount(account, undefined)` (KEYLESS — no
  privateKey embedded; see `docs/security.md`'s session-signer
  rationale), and (4) emit a `delegation.state_changed{state:
  "granted"}` callback whose `permission` block carries the
  artifact set Phoenix's `apply_callback/1` already decodes.

  Accepts a map with:
    * `:smart_account_id` (required) — Phoenix's smart-account id.
    * `:chain_id` (required) — 8453 (Base) or 84532 (Base Sepolia).
    * `:account` (required) — the EOA the browser session signed
      from, threaded through for audit.
    * `:scope` (optional) — caller-supplied policy hints. The
      adapter is free to attach its own policy interpretation; the
      raw map is echoed back on the callback.
    * `:delegation_payload` (optional) — opaque blob the JS hook
      built (signed delegation parameters); the adapter persists it
      in audit trails but does not parse it.
    * `:correlation_id` (optional) — null-able UUID; the
      synchronous response carries it back.

  Returns `{:ok, %{accepted: true, smart_account_id: id}}` on
  HTTP 202, mapped error tuples otherwise.

  The actual delegation row in Phoenix is created later, when the
  adapter posts the `delegation.state_changed{state: "granted"}`
  callback through `BankWeb.Internal.AdapterCallbackController`.
  This dispatch is fire-and-forget for the row; callers that need
  the persisted record must observe the callback path.
  """
  @spec dispatch_grant_delegation(map(), keyword()) ::
          {:ok, grant_ok()} | {:error, grant_error()}
  def dispatch_grant_delegation(
        %{
          smart_account_id: smart_account_id,
          chain_id: chain_id,
          account: account
        } = args,
        opts \\ []
      )
      when is_binary(smart_account_id) and is_integer(chain_id) and is_binary(account) do
    payload = %{
      contract_version: @contract_version,
      action: "grant_delegation",
      smart_account_id: smart_account_id,
      chain_id: chain_id,
      account: account,
      scope: Map.get(args, :scope, %{}),
      delegation_payload: Map.get(args, :delegation_payload),
      correlation_id: Map.get(args, :correlation_id),
      emitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    post("/dispatch/grant_delegation", payload, :grant, opts)
  end

  # --- Payload shaping ---------------------------------------------------

  defp build_transfer_payload(%ExecutionPlan{} = plan) do
    with {:ok, intent} <- fetch_intent(plan),
         {:ok, target} <- resolve_target(intent) do
      {:ok,
       %{
         contract_version: @contract_version,
         action: "transfer",
         execution_plan_id: plan.id,
         intent_id: plan.intent_id,
         smart_account_id: plan.smart_account_id,
         chain: plan.chain,
         asset: plan.asset,
         amount: decimal_to_string(intent.amount),
         target: target,
         signing_requirements: signing_requirements(plan),
         correlation_id: plan.intent_id,
         emitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  # Reconciled with merged #192 (`chain_adapter/src/contracts/schemas.ts`'s
  # `DispatchSwapSchema`). The wire envelope keeps the v0.1 top-level
  # dispatch fields (`input_asset`, `output_asset`, `input_amount`,
  # `expected_output`, `slippage_bps`) and carries the #190 / #192
  # execution-route fields (route_provider, swap_target_contract,
  # spender, calldata, source/destination_token_address,
  # minimum_output_amount, value, deadline) under `route` alongside
  # `venue` and `path`. Adapter consumes the route fields directly
  # to build the approve+swap UserOperation; an absent execution
  # field aborts the dispatch with `swap_route_incomplete: <field>`.
  defp build_swap_payload(%ExecutionPlan{} = plan) do
    with {:ok, _intent} <- fetch_intent(plan),
         {:ok, steps} <- extract_swap_steps(plan) do
      {:ok,
       %{
         contract_version: @contract_version,
         action: "swap",
         execution_plan_id: plan.id,
         intent_id: plan.intent_id,
         smart_account_id: plan.smart_account_id,
         chain: plan.chain,
         input_asset: Map.get(steps, "source_asset"),
         output_asset: Map.get(steps, "destination_asset"),
         input_amount: Map.get(steps, "input_amount"),
         expected_output: Map.get(steps, "expected_output_amount"),
         slippage_bps: Map.get(steps, "slippage_bps"),
         route: %{
           venue: Map.get(steps, "route_provider"),
           path: [
             Map.get(steps, "source_asset"),
             Map.get(steps, "destination_asset")
           ],
           route_provider: Map.get(steps, "route_provider"),
           swap_target_contract: Map.get(steps, "swap_target_contract"),
           spender: Map.get(steps, "spender"),
           calldata: Map.get(steps, "calldata"),
           source_token_address: Map.get(steps, "source_token_address"),
           destination_token_address: Map.get(steps, "destination_token_address"),
           minimum_output_amount: Map.get(steps, "minimum_output_amount"),
           value: Map.get(steps, "value"),
           deadline: Map.get(steps, "deadline")
         },
         signing_requirements: signing_requirements(plan),
         correlation_id: plan.intent_id,
         emitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  # The Morpho deposit payload is intentionally narrow: vault
  # address, asset, amount, receiver smart account, snapshot
  # identity, policy rule ids. No calldata, no spender, no target
  # contract — the adapter builds ERC-4626 deposit + bounded ERC-20
  # approve calldata itself from these primitives. The receiver IS
  # the smart account (acceptance: "Deposit receiver is the smart
  # account"); the adapter resolves the on-chain account address
  # from `smart_account_id`.
  defp build_morpho_deposit_payload(%ExecutionPlan{} = plan) do
    with {:ok, intent} <- fetch_intent(plan),
         {:ok, steps} <- fetch_morpho_steps(plan) do
      {:ok,
       %{
         contract_version: @contract_version,
         action: "morpho_deposit",
         execution_plan_id: plan.id,
         intent_id: plan.intent_id,
         smart_account_id: plan.smart_account_id,
         chain: plan.chain,
         asset: plan.asset,
         amount: decimal_to_string(intent.amount),
         vault_address: Map.fetch!(steps, "vault_address"),
         receiver: Map.fetch!(steps, "receiver"),
         snapshot_id: Map.get(steps, "snapshot_id"),
         snapshot_payload_hash: Map.get(steps, "snapshot_payload_hash"),
         policy_rule_ids: Map.get(steps, "policy_rule_ids", []),
         signing_requirements: signing_requirements(plan),
         correlation_id: plan.intent_id,
         emitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  # The persisted `:steps` JSON is the source of truth for the route
  # (#190). A plan without the swap kind marker is a programming
  # error from the caller (`RunExecution` should only invoke
  # `dispatch_swap/2` for swap plans); fail closed.
  defp extract_swap_steps(%ExecutionPlan{steps: %{"kind" => "swap"} = steps}),
    do: {:ok, steps}

  defp extract_swap_steps(_plan), do: {:error, {:invalid_swap_plan, :missing_route}}

  defp fetch_morpho_steps(%ExecutionPlan{steps: %{"kind" => "morpho_deposit"} = steps}),
    do: {:ok, steps}

  defp fetch_morpho_steps(_), do: {:error, {:target_not_resolvable, :morpho_steps_missing}}

  defp fetch_intent(%ExecutionPlan{intent: %AgentIntent{} = intent}), do: {:ok, intent}

  defp fetch_intent(%ExecutionPlan{intent_id: id}) when is_binary(id) do
    case Repo.get(AgentIntent, id) do
      %AgentIntent{} = intent -> {:ok, intent}
      nil -> {:error, {:target_not_resolvable, :intent_missing}}
    end
  end

  defp resolve_target(%AgentIntent{target_address_label_id: label_id})
       when is_binary(label_id) do
    case Repo.get(AddressLabel, label_id) do
      %AddressLabel{retired_at: nil} = label ->
        {:ok, %{address: label.address, counterparty_id: label.counterparty_id}}

      %AddressLabel{} ->
        {:error, {:target_not_resolvable, :label_retired}}

      nil ->
        {:error, {:target_not_resolvable, :label_missing}}
    end
  end

  defp resolve_target(%AgentIntent{
         target_counterparty_id: cp_id,
         chain: chain
       })
       when is_binary(cp_id) and is_binary(chain) do
    labels =
      Repo.all(
        from(l in AddressLabel,
          where:
            l.counterparty_id == ^cp_id and
              l.chain == ^chain and
              is_nil(l.retired_at),
          order_by: [asc: l.inserted_at]
        )
      )

    case labels do
      [label] -> {:ok, %{address: label.address, counterparty_id: label.counterparty_id}}
      [] -> {:error, {:target_not_resolvable, :no_label}}
      _ -> {:error, {:target_not_resolvable, :ambiguous_label}}
    end
  end

  defp resolve_target(%AgentIntent{target_raw_address: addr}) when is_binary(addr) do
    {:ok, %{address: addr, counterparty_id: nil}}
  end

  defp resolve_target(_) do
    {:error, {:target_not_resolvable, :missing_target}}
  end

  defp signing_requirements(%ExecutionPlan{signing_requirements: sr}) when is_map(sr), do: sr
  defp signing_requirements(_), do: %{}

  # --- HTTP --------------------------------------------------------------

  defp post(path, payload, kind, opts) do
    config = Application.fetch_env!(:bank, __MODULE__)
    base_url = Keyword.fetch!(config, :base_url)
    secret = Keyword.fetch!(config, :dispatch_secret)
    extra_req_options = Keyword.get(config, :req_options, [])

    # Derive correlation metadata from the **request payload** before
    # the HTTP call so every outcome branch can tie its telemetry back
    # to the same intent/plan/smart-account, including the failure
    # paths where we never see a parsed response (4xx/5xx/transport
    # error/invalid-response). Hard-allowlist of safe identifiers; we
    # never thread the raw payload, target address, signing
    # requirements, delegation payload, or permission blob through
    # telemetry.
    request_corr = request_correlation(kind, payload)

    req_opts =
      [
        base_url: base_url,
        url: path,
        method: :post,
        headers: [
          {"authorization", "Bearer " <> secret},
          {"content-type", "application/json"}
        ],
        json: payload,
        receive_timeout: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
        retry: false
      ]
      |> Keyword.merge(extra_req_options)
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        case parse_accepted(kind, body) do
          {:ok, _payload} = ok ->
            telemetry(path, :accepted, status, ok, request_corr)
            ok

          {:error, :invalid_response} = err ->
            telemetry(path, :invalid_response, status, err, request_corr)
            err
        end

      {:ok, %Req.Response{status: status, body: body}} when status in 400..499 ->
        telemetry(path, :rejected, status, nil, request_corr)
        {:error, {:adapter_rejected, status, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        telemetry(path, :error, status, nil, request_corr)
        {:error, {:adapter_error, status, body}}

      {:error, reason} ->
        # Sanitized log: only the reason kind is logged. `inspect(reason)`
        # would carry the full Req error struct, including the request
        # URL (which can carry tokenized RPC userinfo) and any
        # `:transport_options` containing client-side TLS material.
        # `category/1` collapses into a fixed label set; the structured
        # telemetry event is the durable record for ops dashboards.
        Logger.warning(
          "Bank.AdapterClient #{path} unavailable (category=#{reason_category(reason)})"
        )

        telemetry(path, :unavailable, nil, nil, request_corr)
        {:error, :adapter_unavailable}
    end
  end

  # `outcome_meta` is the caller's `{:ok, payload}` / `{:error, reason}`
  # tuple — we extract a small safe-by-construction correlation slice
  # from the parsed response. `request_corr` is the same slice derived
  # from the OUTBOUND payload before the HTTP call, so failure
  # branches that never see a parsed response still carry correlation.
  # Response-side keys win on conflict so the adapter's authoritative
  # `execution_plan_id` (which the contract guarantees matches the
  # outbound one) is the value rendered to ops dashboards.
  defp telemetry(path, outcome, status, outcome_meta, request_corr) do
    meta = request_corr
    meta = if is_integer(status), do: Map.put(meta, :status, status), else: meta
    meta = Map.merge(meta, outcome_meta_correlation(outcome_meta))

    Bank.Runtime.Telemetry.adapter_dispatch(path, outcome, meta)
  end

  # Pull a safe correlation slice off the OUTBOUND request payload.
  # Per `Bank.Runtime.Telemetry.adapter_dispatch/3`'s allowlist, only
  # `:execution_plan_id`, `:intent_id`, and `:smart_account_id` flow
  # through. Address/target, signing requirements, delegation payload,
  # permission blob, and Authorization headers are intentionally
  # NEVER copied even though they may exist on the payload.
  defp request_correlation(kind, %{
         execution_plan_id: ep_id,
         intent_id: intent_id,
         smart_account_id: sa_id
       })
       when kind in [:transfer, :swap] and is_binary(ep_id) and is_binary(intent_id) and
              is_binary(sa_id) do
    %{execution_plan_id: ep_id, intent_id: intent_id, smart_account_id: sa_id}
  end

  defp request_correlation(kind, %{smart_account_id: sa_id})
       when kind in [:revoke, :grant] and is_binary(sa_id),
       do: %{smart_account_id: sa_id}

  defp request_correlation(_, _), do: %{}

  defp outcome_meta_correlation({:ok, %{execution_plan_id: id}}) when is_binary(id),
    do: %{execution_plan_id: id}

  defp outcome_meta_correlation({:ok, %{smart_account_id: id}}) when is_binary(id),
    do: %{smart_account_id: id}

  defp outcome_meta_correlation(_), do: %{}

  # Maps a Req transport reason to a fixed label so logs/telemetry
  # never carry the raw struct. Anything beyond the named cases
  # collapses to `:transport_error` — `inspect/1` on the reason would
  # leak the request URL (with embedded credentials) or transport
  # options (with TLS material), neither of which is safe to log.
  defp reason_category(%Req.TransportError{reason: :timeout}), do: :timeout
  defp reason_category(%Req.TransportError{reason: :econnrefused}), do: :econnrefused
  defp reason_category(%Req.TransportError{reason: :nxdomain}), do: :nxdomain
  defp reason_category(%Req.TransportError{}), do: :transport_error
  defp reason_category(:timeout), do: :timeout
  defp reason_category(:econnrefused), do: :econnrefused
  defp reason_category(:nxdomain), do: :nxdomain
  defp reason_category(_), do: :transport_error

  defp parse_accepted(kind, %{"accepted" => true, "execution_plan_id" => id})
       when kind in [:transfer, :swap] and is_binary(id) do
    {:ok, %{accepted: true, execution_plan_id: id}}
  end

  defp parse_accepted(:revoke, %{"accepted" => true, "smart_account_id" => id})
       when is_binary(id) do
    {:ok, %{accepted: true, smart_account_id: id}}
  end

  defp parse_accepted(:grant, %{"accepted" => true, "smart_account_id" => id})
       when is_binary(id) do
    {:ok, %{accepted: true, smart_account_id: id}}
  end

  defp parse_accepted(_, body) do
    # Don't `inspect(body)` — adapter-supplied JSON could echo back
    # tokens, IDs, or worse. Log only the body's top-level shape so
    # operators can spot "got string instead of map" without seeing
    # the actual values. The :invalid_response telemetry event in
    # `dispatch/3` is the durable signal.
    Logger.warning("Bank.AdapterClient: unexpected 2xx body (shape=#{body_shape(body)})")
    {:error, :invalid_response}
  end

  # The body is adapter-controlled JSON. Even the KEYS can be
  # secret-bearing (`%{"Authorization: Bearer xxx" => "x"}` would
  # surface a header through what looks like a "shape" log). Log
  # only the top-level kind and a count — never any caller-controlled
  # string. Operators can still tell "got map instead of expected
  # `accepted: true` envelope" from the kind + count, and the
  # `[:bank, :adapter, :dispatch]` `:invalid_response` telemetry
  # event is the durable signal anyway.
  defp body_shape(body) when is_map(body), do: "map(key_count=#{map_size(body)})"
  defp body_shape(body) when is_list(body), do: "list(len=#{length(body)})"
  defp body_shape(body) when is_binary(body), do: "string(len=#{byte_size(body)})"
  defp body_shape(body) when is_number(body), do: "number"
  defp body_shape(nil), do: "nil"
  defp body_shape(_), do: "other"

  defp decimal_to_string(nil), do: nil

  defp decimal_to_string(%Decimal{} = d),
    do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp decimal_to_string(other), do: to_string(other)
end
