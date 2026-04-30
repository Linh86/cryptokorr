defmodule Bank.APIKeys.APIKeyTest do
  @moduledoc """
  Schema-level coverage for `Bank.APIKeys.APIKey` (#218a).
  Validations, soft-revocation idempotency, and the `expired?/2`
  predicate. The full create/audit lifecycle is covered by
  `Bank.APIKeysTest`.
  """

  use Bank.DataCase, async: true

  alias Bank.APIKeys.APIKey

  describe "create_changeset/2" do
    test "requires the core fields" do
      changeset = APIKey.create_changeset(%APIKey{}, %{})

      refute changeset.valid?

      missing =
        changeset.errors
        |> Keyword.keys()
        |> MapSet.new()

      for required <- [
            :workspace_id,
            :created_by_user_id,
            :role,
            :name,
            :prefix,
            :secret_hash
          ] do
        assert MapSet.member?(missing, required), "expected #{required} to be required"
      end
    end

    test "rejects an unknown role" do
      changeset =
        APIKey.create_changeset(%APIKey{}, %{
          workspace_id: Ecto.UUID.generate(),
          created_by_user_id: Ecto.UUID.generate(),
          role: :superuser,
          name: "x",
          prefix: "12345678",
          secret_hash: <<0>>
        })

      refute changeset.valid?
      assert {:role, _} = List.keyfind(changeset.errors, :role, 0)
    end

    test "rejects a prefix that is not exactly 8 chars" do
      changeset =
        APIKey.create_changeset(%APIKey{}, %{
          workspace_id: Ecto.UUID.generate(),
          created_by_user_id: Ecto.UUID.generate(),
          role: :viewer,
          name: "x",
          prefix: "tooshort",
          secret_hash: <<0>>
        })

      assert changeset.valid?

      changeset =
        APIKey.create_changeset(%APIKey{}, %{
          workspace_id: Ecto.UUID.generate(),
          created_by_user_id: Ecto.UUID.generate(),
          role: :viewer,
          name: "x",
          prefix: "way-too-long",
          secret_hash: <<0>>
        })

      refute changeset.valid?
    end

    test "rejects an empty name" do
      changeset =
        APIKey.create_changeset(%APIKey{}, %{
          workspace_id: Ecto.UUID.generate(),
          created_by_user_id: Ecto.UUID.generate(),
          role: :viewer,
          name: "",
          prefix: "12345678",
          secret_hash: <<0>>
        })

      refute changeset.valid?
      assert {:name, _} = List.keyfind(changeset.errors, :name, 0)
    end
  end

  describe "revoke_changeset/1" do
    test "stamps revoked_at on a fresh key" do
      changeset = APIKey.revoke_changeset(%APIKey{revoked_at: nil})
      assert %DateTime{} = Ecto.Changeset.get_change(changeset, :revoked_at)
    end

    test "is idempotent on an already-revoked key (no-op changeset)" do
      prior = ~U[2026-04-29 10:00:00.000000Z]
      changeset = APIKey.revoke_changeset(%APIKey{revoked_at: prior})

      # No change emitted — calling Repo.update would be a no-op,
      # which is exactly the "idempotent revoke" contract.
      assert changeset.changes == %{}
    end
  end

  describe "revoked?/1" do
    test "false for nil revoked_at, true otherwise" do
      refute APIKey.revoked?(%APIKey{revoked_at: nil})
      assert APIKey.revoked?(%APIKey{revoked_at: DateTime.utc_now()})
    end
  end

  describe "expired?/2" do
    test "false when expires_at is nil" do
      now = ~U[2026-04-30 12:00:00Z]
      refute APIKey.expired?(%APIKey{expires_at: nil}, now)
    end

    test "false when expires_at is in the future" do
      now = ~U[2026-04-30 12:00:00Z]
      future = ~U[2027-04-30 12:00:00Z]
      refute APIKey.expired?(%APIKey{expires_at: future}, now)
    end

    test "true when expires_at is in the past" do
      now = ~U[2026-04-30 12:00:00Z]
      past = ~U[2026-04-29 12:00:00Z]
      assert APIKey.expired?(%APIKey{expires_at: past}, now)
    end

    test "true when expires_at equals now (boundary, fail-closed)" do
      now = ~U[2026-04-30 12:00:00Z]
      assert APIKey.expired?(%APIKey{expires_at: now}, now)
    end
  end
end
