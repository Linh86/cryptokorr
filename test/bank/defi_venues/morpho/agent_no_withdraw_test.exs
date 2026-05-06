defmodule Bank.DefiVenues.Morpho.AgentNoWithdrawTest do
  @moduledoc """
  Pin the #207 invariant: **agents cannot withdraw**.

  The product rule is permanent: agents can park capital
  (`allocate_idle_capital` deposit) but only operators can
  withdraw. This test file fails closed if a future change
  silently introduces an agent withdraw path through any of:

    * `Bank.Intents.AgentIntent.@kinds` — must NOT contain
      `:withdraw` or `:redeem`.
    * `Bank.Intents.normalize/1` — public boundary must reject
      every plausible withdraw kind string.
    * The agent-facing `Bank.Intents` module surface — must not
      export any `submit_withdraw` / `withdraw_for_agent` /
      `request_withdraw_intent` helper.
    * `BankWeb.OpenApi.Schemas.Intents` — request/response enum
      must NOT contain `withdraw` / `redeem` / `morpho_withdraw`.

  These are source-pin / boundary tests — they don't call any
  on-chain or HTTP path; they assert that the codebase carries no
  agent-callable withdraw construct.
  """

  use ExUnit.Case, async: true

  alias Bank.Intents
  alias Bank.Intents.AgentIntent

  describe "AgentIntent.@kinds — withdraw is not a valid kind" do
    # `Ecto.Enum.values/2` returns the canonical values list for a
    # schema's parameterised enum field. Stable across the Ecto
    # versions we care about; avoids brittle pattern-matching on
    # `__schema__(:type, ...)`'s internal tuple shape.
    defp agent_intent_kinds, do: Ecto.Enum.values(AgentIntent, :kind)

    test "does not contain :withdraw" do
      refute :withdraw in agent_intent_kinds(),
             "AgentIntent.@kinds must not include :withdraw"
    end

    test "does not contain :redeem" do
      refute :redeem in agent_intent_kinds(),
             "AgentIntent.@kinds must not include :redeem"
    end

    test "does not contain :morpho_withdraw" do
      refute :morpho_withdraw in agent_intent_kinds(),
             "AgentIntent.@kinds must not include :morpho_withdraw"
    end

    test "documents the v0.1 allowlist for the historical record" do
      # v0.1 allowlist as of #207. Adding a NEW kind here is a
      # deliberate product decision; this test exists so a future
      # edit that adds `:withdraw` (or similar) breaks loudly.
      assert Enum.sort(agent_intent_kinds()) ==
               Enum.sort([:transfer, :swap, :scheduled_transfer, :defi_yield_deposit])
    end
  end

  describe "Bank.Intents.normalize/1 — public boundary rejects withdraw strings" do
    defp valid_body(overrides) do
      %{
        "idempotency_key" => "k-#{System.unique_integer([:positive])}",
        "source" => "agent",
        "agent_id" => "agent-#{System.unique_integer([:positive])}",
        "kind" => "transfer",
        "asset" => "USDC",
        "chain" => "base",
        "amount" => "12.50",
        "target" => %{"raw_address" => "0xabcdef0000000000000000000000000000000001"}
      }
      |> Map.merge(overrides)
    end

    test ~s/rejects "withdraw" with {:invalid, :kind}/ do
      assert {:error, {:invalid, :kind}} = Intents.normalize(valid_body(%{"kind" => "withdraw"}))
    end

    test ~s/rejects "redeem"/ do
      assert {:error, {:invalid, :kind}} = Intents.normalize(valid_body(%{"kind" => "redeem"}))
    end

    test ~s/rejects "morpho_withdraw"/ do
      assert {:error, {:invalid, :kind}} =
               Intents.normalize(valid_body(%{"kind" => "morpho_withdraw"}))
    end

    test ~s/rejects "morpho_redeem"/ do
      assert {:error, {:invalid, :kind}} =
               Intents.normalize(valid_body(%{"kind" => "morpho_redeem"}))
    end

    test ~s/rejects "deallocate_idle_capital" (the inverse of the deposit kind)/ do
      assert {:error, {:invalid, :kind}} =
               Intents.normalize(valid_body(%{"kind" => "deallocate_idle_capital"}))
    end

    test ~s/rejects "withdraw_idle_capital"/ do
      assert {:error, {:invalid, :kind}} =
               Intents.normalize(valid_body(%{"kind" => "withdraw_idle_capital"}))
    end
  end

  describe "Bank.Intents module surface — no agent withdraw helpers exported" do
    test "no submit_withdraw / withdraw / withdraw_for_agent / request_withdraw_intent functions" do
      forbidden_function_names = ~w(
        submit_withdraw
        withdraw
        withdraw_for_agent
        request_withdraw_intent
        request_morpho_withdraw
      )a

      exports = Intents.__info__(:functions) |> Enum.map(&elem(&1, 0))

      offenders = Enum.filter(forbidden_function_names, &(&1 in exports))

      assert offenders == [],
             "Bank.Intents must not export agent-facing withdraw helpers; found: #{inspect(offenders)}"
    end
  end

  describe "OpenAPI request/response schema — no withdraw kind on the wire" do
    test "IntentSubmissionRequest kind enum does not contain withdraw / redeem variants" do
      schema = BankWeb.OpenApi.Schemas.IntentSubmissionRequest.schema()
      enum = schema.properties.kind.enum

      assert is_list(enum)

      forbidden = ~w(withdraw redeem morpho_withdraw morpho_redeem deallocate_idle_capital)

      Enum.each(forbidden, fn kind ->
        refute kind in enum,
               "IntentSubmissionRequest kind enum must not contain `#{kind}` (operator-only path)"
      end)
    end

    test "IntentEntity kind enum does not contain withdraw / redeem variants" do
      schema = BankWeb.OpenApi.Schemas.IntentEntity.schema()
      enum = schema.properties.kind.enum

      assert is_list(enum)

      forbidden = ~w(withdraw redeem morpho_withdraw morpho_redeem deallocate_idle_capital)

      Enum.each(forbidden, fn kind ->
        refute kind in enum,
               "IntentEntity kind enum must not contain `#{kind}` (operator-only path)"
      end)
    end
  end
end
