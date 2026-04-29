defmodule Bank.Accounts.UserTest do
  @moduledoc """
  Pure changeset tests for `Bank.Accounts.User`. The Repo-roundtrip
  paths live in `Bank.AccountsTest`; this module pins the validation
  surface (required fields, email format, status enum, token-like
  attr rejection).
  """

  use Bank.DataCase, async: true

  alias Bank.Accounts.User

  describe "registration_changeset/2" do
    test "is valid with the minimum identity claims" do
      attrs = %{
        provider: :google,
        provider_subject: "google-sub-1",
        email: "alice@example.com",
        last_login_at: DateTime.utc_now()
      }

      changeset = User.registration_changeset(%User{}, attrs)
      assert changeset.valid?
    end

    test "requires email, provider, provider_subject" do
      changeset = User.registration_changeset(%User{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert errors[:email]
      assert errors[:provider]
      assert errors[:provider_subject]
    end

    test "rejects malformed emails" do
      changeset =
        User.registration_changeset(%User{}, %{
          provider: :google,
          provider_subject: "google-sub-2",
          email: "not-an-email"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:email]
    end

    test "rejects unknown statuses" do
      attrs = %{
        provider: :google,
        provider_subject: "google-sub-3",
        email: "alice@example.com",
        status: :super_admin
      }

      changeset = User.registration_changeset(%User{}, attrs)
      refute changeset.valid?
    end

    for forbidden <- [
          :access_token,
          :refresh_token,
          :id_token,
          :raw_response,
          :token,
          :authorization,
          :auth_code,
          :code,
          :state
        ] do
      test "rejects atom-keyed token-like attr #{inspect(forbidden)}" do
        attrs =
          %{
            provider: :google,
            provider_subject: "google-sub-#{:erlang.phash2(unquote(forbidden))}",
            email: "alice@example.com"
          }
          |> Map.put(unquote(forbidden), "should-never-reach-the-db")

        changeset = User.registration_changeset(%User{}, attrs)
        refute changeset.valid?
        assert errors_on(changeset)[:base]
      end
    end

    for forbidden <- ["access_token", "id_token", "refresh_token", "code"] do
      test "rejects string-keyed token-like attr #{inspect(forbidden)}" do
        attrs = %{
          "provider" => "google",
          "provider_subject" => "google-sub-string-#{:erlang.phash2(unquote(forbidden))}",
          "email" => "alice@example.com",
          unquote(forbidden) => "should-never-reach-the-db"
        }

        changeset = User.registration_changeset(%User{}, attrs)
        refute changeset.valid?
        assert errors_on(changeset)[:base]
      end
    end
  end

  describe "login_refresh_changeset/2" do
    test "only refreshes name / avatar_url / last_login_at" do
      user = %User{
        id: Ecto.UUID.generate(),
        provider: :google,
        provider_subject: "google-sub-4",
        email: "alice@example.com",
        status: :active,
        name: "Old Name",
        avatar_url: nil
      }

      now = DateTime.utc_now()

      changeset =
        User.login_refresh_changeset(user, %{
          name: "New Name",
          avatar_url: "https://example.com/avatar.png",
          last_login_at: now,
          # Identity attrs in the refresh payload must be ignored.
          email: "tampered@example.com",
          provider: :google,
          provider_subject: "tampered-sub",
          status: :active
        })

      assert changeset.valid?
      assert get_change(changeset, :name) == "New Name"
      assert get_change(changeset, :avatar_url) == "https://example.com/avatar.png"
      assert get_change(changeset, :last_login_at) == now

      refute Map.has_key?(changeset.changes, :email)
      refute Map.has_key?(changeset.changes, :provider)
      refute Map.has_key?(changeset.changes, :provider_subject)
      refute Map.has_key?(changeset.changes, :status)
    end

    test "still rejects token-like attrs" do
      user = %User{
        id: Ecto.UUID.generate(),
        provider: :google,
        provider_subject: "google-sub-5",
        email: "alice@example.com",
        status: :active
      }

      changeset =
        User.login_refresh_changeset(user, %{
          name: "OK",
          access_token: "leaked-token"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:base]
    end
  end

  describe "status_changeset/2" do
    test "flips to :disabled" do
      user = %User{
        id: Ecto.UUID.generate(),
        provider: :google,
        provider_subject: "x",
        email: "x@example.com",
        status: :active
      }

      changeset = User.status_changeset(user, :disabled)
      assert get_change(changeset, :status) == :disabled
    end

    test "raises on unknown status" do
      user = %User{
        id: Ecto.UUID.generate(),
        provider: :google,
        provider_subject: "x",
        email: "x@example.com",
        status: :active
      }

      assert_raise FunctionClauseError, fn ->
        User.status_changeset(user, :super_admin)
      end
    end
  end
end
