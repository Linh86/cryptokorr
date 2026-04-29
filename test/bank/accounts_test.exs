defmodule Bank.AccountsTest do
  @moduledoc """
  Repo-roundtrip behaviour for `Bank.Accounts` — the identity-only
  context that owns `users`. Pins the OAuth idempotency contract,
  the disabled-user policy, and the email-normalisation guarantee.
  """

  use Bank.DataCase, async: true

  alias Bank.Accounts
  alias Bank.Accounts.User

  defp claims(overrides \\ %{}) do
    Map.merge(
      %{
        provider: :google,
        subject: "google-sub-#{System.unique_integer([:positive])}",
        email: "alice+#{System.unique_integer([:positive])}@example.com",
        name: "Alice",
        avatar_url: nil
      },
      overrides
    )
  end

  describe "find_or_create_from_oauth/1" do
    test "creates a pending_access user on first login" do
      assert {:ok, %User{} = user} = Accounts.find_or_create_from_oauth(claims())
      assert user.status == :pending_access
      assert user.provider == :google
      assert user.last_login_at
    end

    test "is idempotent: same (provider, subject) refreshes instead of inserting" do
      input = claims(%{name: "Alice"})

      assert {:ok, %User{id: id, status: :pending_access}} =
               Accounts.find_or_create_from_oauth(input)

      # Returning login with a refreshed display name + new avatar.
      assert {:ok, %User{id: ^id, name: "Alice Renamed", avatar_url: "https://example.com/a.png"}} =
               Accounts.find_or_create_from_oauth(
                 Map.merge(input, %{
                   name: "Alice Renamed",
                   avatar_url: "https://example.com/a.png"
                 })
               )

      # Only one row exists.
      assert Bank.Repo.aggregate(User, :count) == 1
    end

    test "returning login does not promote a disabled user" do
      assert {:ok, user} = Accounts.find_or_create_from_oauth(claims())
      assert {:ok, %User{status: :disabled}} = Accounts.disable_user(user)

      claims_for_repeat = %{
        provider: user.provider,
        subject: user.provider_subject,
        email: user.email,
        name: "Should Not Promote",
        avatar_url: nil
      }

      assert {:ok, %User{status: :disabled, name: "Should Not Promote"}} =
               Accounts.find_or_create_from_oauth(claims_for_repeat)
    end

    test "normalises email (lowercase + trim) at the boundary" do
      assert {:ok, %User{email: "alice@example.com"}} =
               Accounts.find_or_create_from_oauth(claims(%{email: "  Alice@Example.COM  "}))
    end

    test "rejects token-like fields if a buggy provider sneaks them in" do
      input = Map.put(claims(), :access_token, "leaked")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Accounts.find_or_create_from_oauth(input)

      assert errors_on(changeset)[:base]
      assert Bank.Repo.aggregate(User, :count) == 0
    end
  end

  describe "get_user/1 and get_user_by_provider_subject/2" do
    test "round-trip a fresh user" do
      assert {:ok, %User{id: id, provider: :google, provider_subject: sub}} =
               Accounts.find_or_create_from_oauth(claims())

      assert %User{id: ^id} = Accounts.get_user(id)
      assert %User{id: ^id} = Accounts.get_user_by_provider_subject(:google, sub)
    end

    test "returns nil for unknown ids and tuples" do
      refute Accounts.get_user(Ecto.UUID.generate())
      refute Accounts.get_user_by_provider_subject(:google, "no-such-subject")
    end

    test "tolerates non-binary ids" do
      refute Accounts.get_user(nil)
    end
  end

  describe "session_allowed?/1" do
    test "is false only for :disabled" do
      refute Accounts.session_allowed?(%User{status: :disabled})
      assert Accounts.session_allowed?(%User{status: :pending_access})
      assert Accounts.session_allowed?(%User{status: :active})
    end
  end

  describe "disable_user/1 and reactivate_user/1" do
    test "flip between :pending_access and :disabled" do
      assert {:ok, user} = Accounts.find_or_create_from_oauth(claims())
      assert {:ok, %User{status: :disabled} = disabled} = Accounts.disable_user(user)
      assert {:ok, %User{status: :pending_access}} = Accounts.reactivate_user(disabled)
    end
  end
end
