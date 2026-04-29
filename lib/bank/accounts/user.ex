defmodule Bank.Accounts.User do
  @moduledoc """
  Identity record for an OAuth-authenticated user (epic #153, issue
  #154).

  ## Identity, not capability

  A user row carries who someone is — provider + provider_subject +
  email + display fields. It does **not** carry product access.
  Workspace membership and roles (issue #155) decide what a user
  can do; this module is identity only.

  ## Status

    * `:pending_access` — the user authenticated but is not yet a
      member of any approved workspace. Default for fresh OAuth
      callbacks.
    * `:active` — at least one approved workspace membership exists.
      Set by the workspace/membership layer (issue #155+) — never
      flipped on by this module alone.
    * `:disabled` — operator-disabled. Cannot start a session;
      audit history is preserved.

  ## OAuth secret hygiene

  Access / refresh / id tokens are NEVER stored on this struct. The
  OAuth callback verifies the token, extracts identity claims
  (`sub`, `email`, `name`, optionally `picture`), and persists only
  those. See `Bank.Accounts.OAuthProvider` for the verify boundary.
  """

  use Bank.Schema

  @statuses [:pending_access, :active, :disabled]
  @providers [:google]

  @type t :: %__MODULE__{}

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string

    field :provider, Ecto.Enum, values: @providers
    field :provider_subject, :string

    field :status, Ecto.Enum, values: @statuses, default: :pending_access

    field :last_login_at, :utc_datetime_usec

    timestamps()
  end

  @doc """
  Changeset for creating a new user from a verified OAuth claim. The
  caller supplies the normalized email (lowercased + trimmed); this
  module enforces the rest.
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :avatar_url,
      :provider,
      :provider_subject,
      :status,
      :last_login_at
    ])
    |> validate_required([:email, :provider, :provider_subject])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
    |> validate_inclusion(:status, @statuses)
    |> reject_token_like_fields(attrs)
    |> unique_constraint([:provider, :provider_subject], name: :users_provider_subject_idx)
    |> unique_constraint(:email, name: :users_lower_email_idx)
  end

  @doc """
  Dedicated changeset for refreshing the per-login fields on a
  returning user (`name`, `avatar_url`, `last_login_at`). Keeps
  identity columns (`provider`, `provider_subject`, `email`,
  `status`) immutable so a returning OAuth login cannot accidentally
  promote a `:disabled` user back to `:active` or rewrite who the
  row points at.
  """
  def login_refresh_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :avatar_url, :last_login_at])
    |> reject_token_like_fields(attrs)
  end

  @doc """
  Changeset for an operator status flip. Keeps everything else
  pinned.
  """
  def status_changeset(user, status) when status in @statuses do
    change(user, status: status)
  end

  # Defense in depth: even though `cast/3` only allows the listed
  # fields through, refuse to write attrs that look like OAuth
  # tokens. Keeps a future caller from accidentally adding
  # `access_token` to the cast list.
  @forbidden_token_keys ~w(
    access_token refresh_token id_token raw_response token
    authorization auth_code code state
  )a

  defp reject_token_like_fields(changeset, attrs) when is_map(attrs) do
    forbidden =
      attrs
      |> Map.keys()
      |> Enum.map(&to_string_key/1)
      |> Enum.filter(&token_like?/1)

    Enum.reduce(forbidden, changeset, fn key, cs ->
      add_error(cs, :base, "forbidden token-like field in attrs: #{key}")
    end)
  end

  defp reject_token_like_fields(changeset, _other), do: changeset

  defp to_string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_string_key(key) when is_binary(key), do: key
  defp to_string_key(_), do: ""

  defp token_like?(key) when is_binary(key) do
    Enum.any?(@forbidden_token_keys, fn forbidden ->
      key == Atom.to_string(forbidden)
    end)
  end

  defp token_like?(_), do: false
end
