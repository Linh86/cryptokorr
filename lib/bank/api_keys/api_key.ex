defmodule Bank.APIKeys.APIKey do
  @moduledoc """
  Workspace-scoped, role-bound machine credential for the `/v1`
  API (#218a).

  Schema-only in this PR. The authentication plug and route
  enforcement land in #218b and reuse `Bank.Workspaces.Membership`'s
  role-hierarchy comparator from #159a.

  ## Storage shape

    * `prefix` — the public lookup token. The first 8 lowercased
      base32 chars of the secret, kept globally unique so the auth
      plug can do an O(log n) prefix lookup before invoking the
      constant-time hash compare. Stored alongside the `cb_`
      namespace prefix on the wire (`cb_<prefix>_<rest>`); we
      strip `cb_` for the column to keep the index narrow.
    * `secret_hash` — `:binary` SHA-256 hash of the raw 32-byte
      secret. The raw secret is shown ONCE on creation and never
      persisted in cleartext anywhere (logs, audit, columns).
    * `role` — `:viewer | :operator | :admin | :owner`, mirroring
      `Bank.Workspaces.Membership.role` so `Plugs.RequireRole`
      (#159a) can reuse the same hierarchy whether the request is
      session- or key-authenticated.
    * `revoked_at` — soft-revoke marker. Once set, `revoked?/1`
      returns `true` and the auth plug (in #218b) MUST refuse the
      key. Schema does not enforce auth; that contract lives in
      `Bank.APIKeys.create_key/4` (refuses re-creation of an active
      revoked-key id) and the future plug.
    * `expires_at` — optional TTL. Schema does not enforce; the
      auth plug compares against `DateTime.utc_now/0`.
    * `last_used_at` — populated by the auth plug, aggregated to
      avoid per-request churn. Stays NULL until #218b lands.

  ## Out of scope

  No password-style hashing (Argon2/bcrypt) — keys are 256-bit
  random secrets, not user-typed passwords. SHA-256 is the right
  algorithm for high-entropy server-checked tokens. A future PR
  can add `secret_hash_version` if rotation becomes necessary; for
  now `secret_hash` is single-version.
  """

  use Bank.Schema

  alias Bank.Accounts.User
  alias Bank.Workspaces.Workspace

  @roles [:viewer, :operator, :admin, :owner]

  @type t :: %__MODULE__{}

  # Redact `:secret_hash` from the default `inspect/1` output. SHA-
  # 256 is one-way, so the hash itself is not a credential, but it
  # IS the value the auth plug looks up by alongside the prefix —
  # logging the hash bytes alongside the prefix gives an attacker
  # the exact pair the plug compares against. Belt-and-suspenders
  # alongside the audit-snapshot allowlist (#218a hygiene contract).
  @derive {Inspect, except: [:secret_hash]}

  schema "api_keys" do
    field :role, Ecto.Enum, values: @roles
    field :name, :string
    field :prefix, :string
    field :secret_hash, :binary
    field :last_used_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :created_by, User, foreign_key: :created_by_user_id

    timestamps()
  end

  @doc """
  Changeset for inserting a fresh key. The `:secret_hash` and
  `:prefix` are produced by `Bank.APIKeys.create_key/4`; callers do
  not pass the raw secret through this changeset.
  """
  def create_changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [
      :workspace_id,
      :created_by_user_id,
      :role,
      :name,
      :prefix,
      :secret_hash,
      :expires_at
    ])
    |> validate_required([
      :workspace_id,
      :created_by_user_id,
      :role,
      :name,
      :prefix,
      :secret_hash
    ])
    |> validate_inclusion(:role, @roles)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:prefix, is: 8)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> unique_constraint(:prefix, name: :api_keys_prefix_index)
  end

  @doc """
  Changeset for soft-revocation. Idempotent — rows already
  revoked carry their original `revoked_at` forward unchanged.
  """
  def revoke_changeset(%__MODULE__{revoked_at: nil} = api_key) do
    change(api_key, revoked_at: DateTime.utc_now())
  end

  def revoke_changeset(%__MODULE__{} = api_key) do
    # Already revoked — no-op changeset preserves prior timestamp.
    change(api_key, %{})
  end

  @doc "True iff the key has been soft-revoked."
  @spec revoked?(t()) :: boolean()
  def revoked?(%__MODULE__{revoked_at: nil}), do: false
  def revoked?(%__MODULE__{}), do: true

  @doc """
  True iff the key has an `expires_at` in the past relative to
  `now`. Keys without `expires_at` never expire.
  """
  @spec expired?(t(), DateTime.t()) :: boolean()
  def expired?(%__MODULE__{expires_at: nil}, _now), do: false

  def expired?(%__MODULE__{expires_at: %DateTime{} = exp}, %DateTime{} = now),
    do: DateTime.compare(exp, now) != :gt

  @doc "Returns the supported role list."
  @spec roles() :: [atom()]
  def roles, do: @roles
end
