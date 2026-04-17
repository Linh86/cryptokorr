defmodule Bank.Ops.HealthTest do
  @moduledoc """
  Direct tests for `Bank.Ops.Health.emit_telemetry/0` and the
  surrounding telemetry-poller config introduced for issue #52.

  These tests do not rely on the `:telemetry_poller` actually firing
  — that is intentionally disabled in the `:test` env (see
  `config/test.exs`) because its background process has no
  per-process `Req.Test` stub. We exercise `emit_telemetry/0` from
  the test process where stubs are installed, and we assert that
  the poller schedule is empty.
  """

  use Bank.DataCase, async: false

  alias Bank.Ops.Health

  describe "BankWeb.Telemetry.periodic_measurements/0" do
    test "is empty in :test so the poller does not call emit_telemetry/0" do
      assert BankWeb.Telemetry.periodic_measurements() == []
    end

    test "default (when no config) still includes the health emit MFA" do
      original = Application.get_env(:bank, BankWeb.Telemetry)

      try do
        Application.delete_env(:bank, BankWeb.Telemetry)

        assert BankWeb.Telemetry.periodic_measurements() == [
                 {Bank.Ops.Health, :emit_telemetry, []}
               ]
      after
        if original do
          Application.put_env(:bank, BankWeb.Telemetry, original)
        end
      end
    end
  end

  describe "emit_telemetry/0 (direct invocation in the test process)" do
    test "emits a [:bank, :ops, :health] event with adapter_up=1 when the stub is healthy" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      ref = attach_handler()

      assert Health.emit_telemetry() == :ok

      assert_receive {:health_event, measurements, %{}}, 500
      assert measurements.adapter_up == 1
      assert measurements.database_up == 1
      assert is_integer(measurements.stuck_plans)

      detach_handler(ref)
    end

    test "emits adapter_up=0 when the adapter transport fails" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      ref = attach_handler()

      assert Health.emit_telemetry() == :ok

      assert_receive {:health_event, measurements, %{}}, 500
      assert measurements.adapter_up == 0
      assert measurements.database_up == 1

      detach_handler(ref)
    end
  end

  defp attach_handler do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:bank, :ops, :health],
      fn _event, measurements, metadata, _ ->
        send(parent, {:health_event, measurements, metadata})
      end,
      nil
    )

    ref
  end

  defp detach_handler(ref) do
    :telemetry.detach({__MODULE__, ref})
  end
end
