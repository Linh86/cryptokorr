defmodule Bank.Audit.EnvelopeTest do
  use ExUnit.Case, async: true

  alias Bank.Audit.Envelope

  @valid_attrs %{
    actor: :runtime,
    event_type: "intent.submitted",
    subject_type: "agent_intent",
    subject_id: "11111111-1111-1111-1111-111111111111",
    correlation_id: "11111111-1111-1111-1111-111111111111"
  }

  describe "build/1" do
    test "normalises attrs, defaults ts + schema_version, sets payload_hash" do
      {:ok, built} = Envelope.build(@valid_attrs)

      assert %DateTime{} = built.ts
      assert built.schema_version == "1"
      assert is_binary(built.payload_hash)
      assert String.length(built.payload_hash) == 64
    end

    test "returns missing fields error when any required field is absent" do
      {:error, {:missing_fields, missing}} =
        Envelope.build(Map.delete(@valid_attrs, :subject_id))

      assert :subject_id in missing
    end

    test "preserves an explicit :ts" do
      fixed = DateTime.from_naive!(~N[2026-04-15 12:00:00.000000], "Etc/UTC")
      {:ok, built} = Envelope.build(Map.put(@valid_attrs, :ts, fixed))
      assert built.ts == fixed
    end

    test "hashing is deterministic across key order" do
      a =
        Envelope.build!(
          actor: :runtime,
          event_type: "intent.submitted",
          subject_type: "agent_intent",
          subject_id: "22222222-2222-2222-2222-222222222222",
          ts: DateTime.from_naive!(~N[2026-04-15 12:00:00.000000], "Etc/UTC")
        )

      b =
        Envelope.build!(
          subject_id: "22222222-2222-2222-2222-222222222222",
          subject_type: "agent_intent",
          event_type: "intent.submitted",
          actor: :runtime,
          ts: DateTime.from_naive!(~N[2026-04-15 12:00:00.000000], "Etc/UTC")
        )

      assert a.payload_hash == b.payload_hash
    end

    test "different payloads produce different hashes" do
      {:ok, a} = Envelope.build(@valid_attrs)
      {:ok, b} = Envelope.build(%{@valid_attrs | event_type: "intent.cancelled"})
      refute a.payload_hash == b.payload_hash
    end

    test "ignores unknown keys in the canonical payload" do
      {:ok, built} = Envelope.build(Map.put(@valid_attrs, :garbage, "junk"))
      refute Map.has_key?(built, :garbage)
    end

    test "passes :workspace_id through to the row but excludes it from payload_hash (#158d-b)" do
      ws_id = "33333333-3333-3333-3333-333333333333"
      ts = DateTime.from_naive!(~N[2026-04-15 12:00:00.000000], "Etc/UTC")

      attrs_without = Map.put(@valid_attrs, :ts, ts)
      attrs_with = Map.put(attrs_without, :workspace_id, ws_id)

      {:ok, without} = Envelope.build(attrs_without)
      {:ok, with_ws} = Envelope.build(attrs_with)

      # Same canonical fields → same payload_hash. Adding the
      # passthrough workspace_id MUST NOT mutate the hash.
      assert without.payload_hash == with_ws.payload_hash

      # The workspace_id is preserved on the writer-shaped attrs.
      assert with_ws.workspace_id == ws_id
      refute Map.has_key?(without, :workspace_id)
    end

    test "two events with the same canonical payload but different workspace_id share a payload_hash" do
      ts = DateTime.from_naive!(~N[2026-04-15 12:00:00.000000], "Etc/UTC")

      {:ok, a} =
        Envelope.build(
          Map.merge(@valid_attrs, %{
            ts: ts,
            workspace_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
          })
        )

      {:ok, b} =
        Envelope.build(
          Map.merge(@valid_attrs, %{
            ts: ts,
            workspace_id: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
          })
        )

      assert a.payload_hash == b.payload_hash
      refute a.workspace_id == b.workspace_id
    end
  end

  describe "build!/1" do
    test "raises on missing fields" do
      assert_raise ArgumentError, fn ->
        Envelope.build!(Map.delete(@valid_attrs, :event_type))
      end
    end
  end
end
