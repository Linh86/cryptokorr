defmodule Bank.Intents.AgentIntentTest do
  use Bank.DataCase, async: true

  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent

  describe "changeset/2 target shape" do
    test "accepts a counterparty-only target" do
      cp = Fixtures.counterparty()

      changeset =
        AgentIntent.changeset(%AgentIntent{}, valid_attrs(target_counterparty_id: cp.id))

      assert changeset.valid?
    end

    test "accepts a raw-address-only target" do
      changeset =
        AgentIntent.changeset(
          %AgentIntent{},
          valid_attrs(target_raw_address: "0xraw")
        )

      assert changeset.valid?
    end

    test "rejects both counterparty and raw address set" do
      cp = Fixtures.counterparty()

      changeset =
        AgentIntent.changeset(
          %AgentIntent{},
          valid_attrs(
            target_counterparty_id: cp.id,
            target_raw_address: "0xraw"
          )
        )

      refute changeset.valid?
      assert errors_on(changeset).target_raw_address != []
    end

    test "rejects neither target set" do
      changeset = AgentIntent.changeset(%AgentIntent{}, valid_attrs())
      refute changeset.valid?
      assert errors_on(changeset).target_counterparty_id != []
    end

    test "rejects an address label without a counterparty" do
      cp = Fixtures.counterparty()
      label = Fixtures.address_label(counterparty: cp)

      changeset =
        AgentIntent.changeset(
          %AgentIntent{},
          valid_attrs(
            target_address_label_id: label.id,
            target_raw_address: "0xraw"
          )
        )

      refute changeset.valid?
      assert errors_on(changeset).target_address_label_id != []
    end
  end

  describe "validations" do
    test "requires the core transfer fields" do
      changeset = AgentIntent.changeset(%AgentIntent{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)

      for field <- [
            :agent_id,
            :source,
            :idempotency_key,
            :payload_hash,
            :kind,
            :asset,
            :chain,
            :amount,
            :submitted_at
          ] do
        assert errors[field], "expected error on #{field}"
      end
    end

    test "rejects non-positive amounts" do
      cp = Fixtures.counterparty()

      changeset =
        AgentIntent.changeset(
          %AgentIntent{},
          valid_attrs(target_counterparty_id: cp.id, amount: Decimal.new("0"))
        )

      refute changeset.valid?
      assert errors_on(changeset).amount != []
    end
  end

  describe "idempotency" do
    test "(agent_id, idempotency_key) uniqueness is enforced at DB" do
      cp = Fixtures.counterparty()

      intent =
        Fixtures.agent_intent(
          counterparty: cp,
          agent_id: "agent-42",
          idempotency_key: "same-key"
        )

      {:error, changeset} =
        %AgentIntent{}
        |> AgentIntent.changeset(
          valid_attrs(
            target_counterparty_id: cp.id,
            agent_id: "agent-42",
            idempotency_key: "same-key"
          )
        )
        |> Repo.insert()

      refute changeset.valid?
      assert changeset.errors[:agent_id] || changeset.errors[:idempotency_key]
      assert intent.id
    end
  end

  describe "current_pointer_changeset/2" do
    test "updates only the cached pointer columns" do
      intent = Fixtures.agent_intent()
      decision_id = Ecto.UUID.generate()

      {:ok, updated} =
        intent
        |> AgentIntent.current_pointer_changeset(%{
          current_decision_id: decision_id,
          state: :decided
        })
        |> Repo.update()

      assert updated.current_decision_id == decision_id
      assert updated.state == :decided
      # business field untouched
      assert updated.idempotency_key == intent.idempotency_key
    end
  end

  defp valid_attrs(overrides \\ %{})
  defp valid_attrs(overrides) when is_list(overrides), do: valid_attrs(Map.new(overrides))

  defp valid_attrs(overrides) when is_map(overrides) do
    %{
      agent_id: "agent-1",
      source: :agent,
      idempotency_key: "idem-#{System.unique_integer([:positive])}",
      payload_hash: "deadbeef",
      kind: :transfer,
      asset: "USDC",
      chain: "base",
      amount: Decimal.new("5"),
      submitted_at: DateTime.utc_now()
    }
    |> Map.merge(overrides)
  end
end
