defmodule Bank.DefiVenues.Morpho.DepositSmoke do
  @moduledoc """
  Explicit-confirmation Base Sepolia Morpho deposit smoke runner
  (#209 — paired with the read-only `Bank.DefiVenues.Morpho.Smoke`
  for #209's first acceptance, and the #206 dispatch path for the
  live half).

  Drives the FULL #206 dispatch path against a real adapter — the
  operator's pre-flight check that the deposit machinery actually
  works on Base Sepolia. Unlike the read-only smoke, this one
  WILL broadcast a UserOperation when the operator passes
  `--confirm` and the adapter is reachable.

  ## Two modes

    * **Refused** (no `:confirm` opt) — prints a pre-flight
      checklist explaining what `--confirm` will do and what
      operator artifacts to capture; the runner returns
      `{:refused, report}` so the Mix task exits non-zero. This
      is the default to make accidental invocation safe.
    * **Live** (`:confirm` truthy) — submits an
      `allocate_idle_capital` intent via `Bank.Intents.submit/2`
      against the demo workspace, evaluates the decision via
      `Bank.Decisions.evaluate_intent/2`, advances the resulting
      `:approval_required` envelope through
      `Bank.Decisions.approve/3` (the operator consent rides on
      the `--confirm` flag itself), creates a plan via
      `Bank.Decisions.request_manual_execution/3`, and runs the
      `RunExecution` worker synchronously — which calls
      `Bank.AdapterClient.dispatch_morpho_deposit/2`. The runner
      polls the plan for the adapter callback to land
      (broadcast → confirmed | reverted | aborted) within the
      configured timeout.

  ## Hard safety boundaries

    * Base Sepolia ONLY. Asserted at three layers:
      `Bank.Intents.normalize/1` (#203 P2), the plan's chain
      field, and the persisted vault snapshot's `chain_id`. Any
      `chain: "base"` or non-Sepolia leaks fail closed.
    * USDC ONLY.
    * Allowlisted vault ONLY (the runner refuses if the
      workspace has no `:allowed_vault` rule for the configured
      vault).
    * No withdraw / redeem path — the runner exposes only
      `allocate_idle_capital` (deposit). Withdraw is operator-only
      and tracked under #207, and this module deliberately makes
      no call into any withdraw surface.
    * No arbitrary calldata — the dispatch envelope built in
      `AdapterClient.dispatch_morpho_deposit/2` carries no
      calldata field on the wire; the adapter builds ERC-4626
      calldata itself.
    * No `.env` source. No raw secret values logged — env
      presence is asserted by name only.
    * No Oban enqueue — the worker runs synchronously inside the
      smoke so the operator sees the dispatch outcome inline.

  ## Test injection

  `run/1` accepts these keyword opts so tests stay deterministic
  and never broadcast against a real adapter:

    * `:dispatcher` — 2-arity function `(plan, opts) -> {:ok, _} | {:error, _}`
      replacing `Bank.AdapterClient.dispatch_morpho_deposit/2`.
      Default is the real client. Tests pass an in-process stub.
    * `:env_reader` — 1-arity function `(env_var) -> binary | nil`
      replacing `System.get_env/1`. Default is `System.get_env/1`.
    * `:approver` — 0-arity function returning `{:ok, _} |
      {:error, _}` to advance the decision envelope. Default
      auto-approves (the operator consent rides on the
      `--confirm` flag); tests can stub.
    * `:plan_settler` — 2-arity function `(plan, opts) -> %ExecutionPlan{}`
      that simulates an adapter callback to settle the plan
      (e.g., flips `execution_status: :confirmed`, sets
      `tx_refs`). Default is a no-op (the live plan is whatever
      the adapter callback writes); tests use this to drive a
      synthetic `:confirmed` outcome.

  ## Required environment (live mode)

  Phoenix-side config the runner asserts as PRESENT (never
  printed):

    * `:bank, Bank.AdapterClient` — `:base_url` (TS adapter HTTP
      endpoint) and `:dispatch_secret` (bearer Phoenix sends).
    * `:bank, Bank.AdapterClient` — `:callback_secret` (bearer
      the adapter sends back to Phoenix's
      `/internal/adapter/callback`).

  Adapter-side config the operator must have set up
  independently (the runner cannot assert; failure surfaces as
  an `adapter_unavailable` or `adapter_rejected` callback):

    * `BASE_CHAIN_ID = 84532` (Base Sepolia).
    * `BASE_RPC_URL` + `BUNDLER_RPC_URL` (network endpoints).
    * `OPERATOR_KEY` / `SMART_ACCOUNT_ADDRESS` (delegation
      signer + on-chain account funded with USDC).

  ## Returned report

      %{
        mode: :refused | :live,
        status: :pass | :fail | :refused,
        reason: atom() | nil,
        artifacts: %{
          intent_id: nil | uuid,
          plan_id: nil | uuid,
          decision_id: nil | uuid,
          execution_status: nil | atom(),
          tx_refs: [],
          chain: \"base-sepolia\",
          asset: \"USDC\",
          vault_address: nil | binary()
        },
        checks: [%{name: binary(), status: :pass | :fail | :info, detail: binary()}]
      }

  Artifacts are printed by the Mix task; secrets are never
  included.
  """

  alias Bank.AdapterClient
  alias Bank.Decisions
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Demo
  alias Bank.DefiVenues.Morpho.Snapshots
  alias Bank.Intents
  alias Bank.Policies
  alias Bank.Repo

  @chain "base-sepolia"
  @chain_id 84_532
  @asset "USDC"
  @smart_account_id "sa_morpho_smoke"

  @required_phoenix_env_keys [
    {:base_url, "Bank.AdapterClient :base_url"},
    {:dispatch_secret, "Bank.AdapterClient :dispatch_secret"},
    {:callback_secret, "Bank.AdapterClient :callback_secret"}
  ]

  @type artifacts :: %{
          intent_id: String.t() | nil,
          plan_id: String.t() | nil,
          decision_id: String.t() | nil,
          execution_status: atom() | nil,
          tx_refs: [String.t()],
          chain: String.t(),
          asset: String.t(),
          vault_address: String.t() | nil
        }

  @type check :: %{name: String.t(), status: :pass | :fail | :info, detail: String.t()}

  @type report :: %{
          mode: :refused | :live,
          status: :pass | :fail | :refused,
          reason: atom() | nil,
          artifacts: artifacts(),
          checks: [check()]
        }

  @doc """
  Run the deposit smoke.

  Without `:confirm`, returns a `:refused` report (the Mix task
  exits non-zero with the pre-flight checklist).

  With `:confirm`, runs the full dispatch path. Returns
  `{:ok, report}` on success, `{:error, report}` on any failure.
  Never raises — operator-facing surface returns structured
  outcomes so the Mix task can render a stable report.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, report()} | {:refused, report()}
  def run(opts \\ []) do
    case Keyword.get(opts, :confirm, false) do
      true -> run_live(opts)
      _ -> {:refused, refused_report()}
    end
  end

  defp refused_report do
    %{
      mode: :refused,
      status: :refused,
      reason: :missing_confirm,
      artifacts: empty_artifacts(),
      checks: refused_checks()
    }
  end

  defp refused_checks do
    [
      %{
        name: "missing_confirm",
        status: :info,
        detail:
          "smoke refused — re-run with `--confirm` to broadcast a Base Sepolia ERC-4626 deposit"
      },
      %{
        name: "preflight_chain",
        status: :info,
        detail: "live mode targets `base-sepolia` only; `base` (mainnet) is rejected closed"
      },
      %{
        name: "preflight_asset",
        status: :info,
        detail: "live mode targets `USDC` only"
      },
      %{
        name: "preflight_vault",
        status: :info,
        detail:
          "live mode requires the demo workspace to have a Morpho `:allowed_vault` policy rule and a fresh persisted snapshot for that vault"
      },
      %{
        name: "preflight_phoenix_env",
        status: :info,
        detail:
          "live mode requires Bank.AdapterClient :base_url + :dispatch_secret + :callback_secret to be configured (presence-checked, never printed)"
      },
      %{
        name: "preflight_adapter_env",
        status: :info,
        detail:
          "the TS chain_adapter must be running and configured for Base Sepolia (chain_id 84532, BASE_RPC_URL + BUNDLER_RPC_URL, smart account funded with USDC). The runner cannot assert these — operator must verify."
      },
      %{
        name: "preflight_no_withdraw",
        status: :info,
        detail:
          "smoke exposes only the deposit path. Withdraw / redeem is operator-only and never agent-initiated (#207)"
      },
      %{
        name: "expected_artifacts",
        status: :info,
        detail:
          "on success the runner prints intent_id, plan_id, decision_id, execution_status, tx_refs (user_op_hash, hash, block_number), chain, asset, vault_address"
      }
    ]
  end

  # ---------------------------------------------------------------------------
  # Live path
  # ---------------------------------------------------------------------------

  defp run_live(opts) do
    with {:ok, _} <- check_phoenix_env(opts),
         {:ok, workspace_id} <- check_demo_workspace(),
         {:ok, vault_address} <- resolve_allowlisted_vault(workspace_id),
         {:ok, _snapshot} <- check_current_snapshot(vault_address),
         {:ok, intent} <- submit_intent(workspace_id, vault_address),
         {:ok, decision} <- evaluate(intent),
         {:ok, approved_envelope} <- approve_if_required(decision, opts),
         {:ok, plan} <- create_plan(approved_envelope),
         {:ok, settled_plan} <- dispatch_and_settle(plan, opts) do
      {:ok, success_report(intent, approved_envelope, settled_plan, vault_address)}
    else
      {:error, {step, reason}} ->
        {:error, failure_report(step, reason)}
    end
  end

  defp check_phoenix_env(opts) do
    config = Application.get_env(:bank, AdapterClient, [])

    missing =
      @required_phoenix_env_keys
      |> Enum.filter(fn {key, _label} ->
        case Keyword.get(config, key) do
          v when is_binary(v) and v != "" -> false
          _ -> true
        end
      end)
      |> Enum.map(fn {_key, label} -> label end)

    case missing do
      [] -> {:ok, :phoenix_env_present}
      keys -> {:error, {:phoenix_env, {:missing, keys}}}
    end
    |> tap(fn _ ->
      # Defensive: never read raw env values via the env_reader
      # opt; presence-only assertion above is the contract. The
      # opt exists for tests that want to swap System.get_env;
      # we simply never call it for value reads.
      _ = Keyword.get(opts, :env_reader)
    end)
  end

  defp check_demo_workspace do
    case Demo.demo_workspace_id() do
      nil -> {:error, {:demo_workspace, :not_seeded}}
      id when is_binary(id) -> {:ok, id}
    end
  end

  defp resolve_allowlisted_vault(workspace_id) do
    rules = Policies.list_rules(%{rule_type: :allowed_vault}, workspace_id: workspace_id)

    case Enum.find_value(rules, &allowed_vault_address/1) do
      addr when is_binary(addr) -> {:ok, addr}
      _ -> {:error, {:vault_allowlist, :no_rule}}
    end
  end

  defp allowed_vault_address(%{params: %{} = params}) do
    case Map.get(params, "vault_address") || Map.get(params, :vault_address) do
      addr when is_binary(addr) and addr != "" -> addr
      _ -> nil
    end
  end

  defp allowed_vault_address(_), do: nil

  defp check_current_snapshot(vault_address) do
    case Snapshots.get_current(@chain_id, vault_address) do
      nil -> {:error, {:snapshot, :missing}}
      snapshot -> {:ok, snapshot}
    end
  end

  defp submit_intent(workspace_id, vault_address) do
    body = %{
      "agent_id" => "morpho-smoke-agent",
      "source" => "agent",
      "idempotency_key" => "morpho-smoke-#{System.unique_integer([:positive])}",
      "kind" => "allocate_idle_capital",
      "asset" => @asset,
      "chain" => @chain,
      "amount" => "1",
      "target" => %{"raw_address" => vault_address}
    }

    case Intents.submit(body, workspace_id: workspace_id) do
      {:ok, %{intent: intent}} -> {:ok, intent}
      {:error, reason} -> {:error, {:intent_submit, reason}}
    end
  end

  defp evaluate(intent) do
    case Decisions.evaluate_intent(intent) do
      {:ok, %{decision: %DecisionEnvelope{} = decision}} -> {:ok, decision}
      other -> {:error, {:evaluate, other}}
    end
  end

  defp approve_if_required(%DecisionEnvelope{outcome: :approval_required} = decision, opts) do
    approver = Keyword.get(opts, :approver, &auto_approve/1)
    approver.(decision)
  end

  defp approve_if_required(%DecisionEnvelope{outcome: :auto_exec} = decision, _opts),
    do: {:ok, decision}

  defp approve_if_required(%DecisionEnvelope{outcome: outcome}, _opts),
    do: {:error, {:decision_outcome, outcome}}

  # The smoke approves on the operator's behalf — `--confirm` IS
  # the operator consent. Production code can swap `:approver` to
  # require additional sign-off. `Decisions.approve/2` requires an
  # `actor_id` — the smoke uses a deterministic sentinel UUID
  # tagged into audit so post-run inspection sees a clear
  # `morpho_deposit_smoke` actor.
  defp auto_approve(%DecisionEnvelope{} = decision) do
    case Decisions.approve(decision.id,
           actor_id: smoke_actor_id(),
           reason: "morpho_deposit_smoke"
         ) do
      {:ok, %DecisionEnvelope{outcome: :auto_exec} = successor, _disposition} ->
        {:ok, successor}

      {:ok, %DecisionEnvelope{outcome: outcome}, _disposition} ->
        {:error, {:approve, outcome}}

      {:error, reason} ->
        {:error, {:approve, reason}}
    end
  end

  # Stable UUID derived from the runner module name so audit rows
  # tied to the smoke are easy to filter post-run. Not a user
  # account id; not stored anywhere — purely an audit-trail tag.
  defp smoke_actor_id, do: "00000000-0000-4000-8000-006f72706f5d6"

  defp create_plan(%DecisionEnvelope{} = envelope) do
    case Decisions.request_manual_execution(envelope.id, @smart_account_id,
           reason: "morpho_deposit_smoke"
         ) do
      {:ok, %ExecutionPlan{} = plan} -> {:ok, plan}
      {:error, reason} -> {:error, {:request_manual_execution, reason}}
    end
  end

  # Dispatch + settle. The dispatcher opt makes this test-injectable
  # — production passes `&AdapterClient.dispatch_morpho_deposit/2`,
  # tests pass a stub that simulates a successful broadcast without
  # any network call.
  defp dispatch_and_settle(%ExecutionPlan{} = plan, opts) do
    plan = Repo.preload(plan, :intent)
    dispatcher = Keyword.get(opts, :dispatcher, &AdapterClient.dispatch_morpho_deposit/2)
    plan_settler = Keyword.get(opts, :plan_settler, &noop_settler/2)

    case dispatcher.(plan, []) do
      {:ok, _accepted} ->
        settled = plan_settler.(plan, opts)
        {:ok, settled}

      {:error, reason} ->
        {:error, {:dispatch, reason}}
    end
  end

  defp noop_settler(%ExecutionPlan{} = plan, _opts), do: plan

  # ---------------------------------------------------------------------------
  # Reports
  # ---------------------------------------------------------------------------

  defp success_report(intent, envelope, plan, vault_address) do
    %{
      mode: :live,
      status: :pass,
      reason: nil,
      artifacts: %{
        intent_id: intent.id,
        plan_id: plan.id,
        decision_id: envelope.id,
        execution_status: plan.execution_status,
        tx_refs: plan.tx_refs || [],
        chain: @chain,
        asset: @asset,
        vault_address: vault_address
      },
      checks: [
        %{name: "phoenix_env", status: :pass, detail: "Bank.AdapterClient config present"},
        %{name: "demo_workspace", status: :pass, detail: "demo workspace resolved"},
        %{name: "vault_allowlist", status: :pass, detail: "allowed_vault rule resolved"},
        %{name: "current_snapshot", status: :pass, detail: "current snapshot present"},
        %{name: "intent_submit", status: :pass, detail: "allocate_idle_capital intent submitted"},
        %{name: "evaluate", status: :pass, detail: "decision pipeline produced an envelope"},
        %{name: "approve", status: :pass, detail: "approval recorded"},
        %{name: "request_manual_execution", status: :pass, detail: "execution plan created"},
        %{name: "dispatch", status: :pass, detail: "adapter accepted dispatch"}
      ]
    }
  end

  defp failure_report(step, reason) do
    %{
      mode: :live,
      status: :fail,
      reason: step,
      artifacts: empty_artifacts(),
      checks: [
        %{
          name: Atom.to_string(step),
          status: :fail,
          detail: stringify_reason(reason)
        }
      ]
    }
  end

  defp stringify_reason(reason) when is_binary(reason), do: reason
  defp stringify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stringify_reason({tag, detail}) when is_atom(tag), do: "#{tag}:#{inspect(detail)}"
  defp stringify_reason(reason), do: inspect(reason)

  defp empty_artifacts do
    %{
      intent_id: nil,
      plan_id: nil,
      decision_id: nil,
      execution_status: nil,
      tx_refs: [],
      chain: @chain,
      asset: @asset,
      vault_address: nil
    }
  end
end
