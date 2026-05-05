defmodule Bank.Workspaces.Workspace do
  @moduledoc """
  A unit of product scope (epic #153, issue #155).

  Counterparties, policies, delegations, intents, decisions all
  eventually pivot off `workspace_id` (#158). This module is the
  identity of a workspace; membership and roles live in
  `Bank.Workspaces.Membership`.

  Slugs are normalised to lowercase at the boundary so a functional
  unique index on `lower(slug)` keeps casing consistent.

  ## Agent-key pause (#231-a)

  Three nullable columns gate workspace-wide agent-key auth:

    * `agent_keys_paused_at` — presence = paused.
    * `agent_keys_paused_reason` — optional operator note (≤ 256 chars).
    * `agent_keys_paused_by_user_id` — human who paused.

  When `agent_keys_paused_at` is non-nil, `Bank.APIKeys.verify_key/1`
  rejects every API key for this workspace with the same wire shape
  as revoked / expired (`401 invalid_credentials`). The pause is a
  workspace-level overlay on otherwise-valid keys; revoke/expire on
  the row itself takes precedence.

  Browser/session admin access goes through `BankWeb.LiveAuth`, NOT
  `BankWeb.Plugs.VerifyAPIKey`, so an admin signed in via Google OAuth
  can still resume a paused workspace from `/security` even when
  every API key is paused. Pure-API-key bootstraps lose access — see
  the limitation note in `Bank.APIKeys`.

  ## Base mainnet eligibility (#178)

  One boolean column on `workspaces`:

    * `mainnet_enabled :boolean default false not null` — `false`
      means the workspace cannot run intents on a mainnet chain
      (`Bank.Chains.mainnet_chains/0`). The runtime, dispatch
      worker, and intent controller all consult
      `Bank.Workspaces.mainnet_enabled?/1` and fail closed with a
      `:mainnet_disabled` held reason when the chain is mainnet
      and the flag is not set. Default `false` makes "mainnet
      disabled" the always-on safety posture.

  The flag is set via `mainnet_changeset/2`, kept apart from the
  user-editable `changeset/2` (slug/name) the same way
  `pause_changeset/2` is separated from generic edits.
  """

  use Bank.Schema

  alias Bank.Accounts.User
  alias Bank.Workspaces.Membership

  @type t :: %__MODULE__{}

  schema "workspaces" do
    field :slug, :string
    field :name, :string

    field :agent_keys_paused_at, :utc_datetime_usec
    field :agent_keys_paused_reason, :string

    belongs_to :agent_keys_paused_by_user, User,
      foreign_key: :agent_keys_paused_by_user_id,
      type: :binary_id

    field :mainnet_enabled, :boolean, default: false

    field :notify_execution_confirmed, :boolean, default: false

    has_many :memberships, Membership

    timestamps()
  end

  @doc """
  Changeset for creating or renaming a workspace.

  `:mainnet_enabled` is intentionally castable here so test fixtures
  and admin bootstraps can stamp the flag at creation time. The
  schema default is `false` (#178), so production code that does not
  pass the field gets the safe default. Any change to this field
  during the lifetime of an existing workspace must go through
  `mainnet_changeset/2` instead — that path emits a separate audit
  trail for the security-relevant flip.
  """
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:slug, :name, :mainnet_enabled, :notify_execution_confirmed])
    |> validate_required([:slug, :name])
    |> update_change(:slug, &normalise_slug/1)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9_-]{0,62}$/,
      message: "must be lowercase alphanumeric, hyphens or underscores"
    )
    |> unique_constraint(:slug, name: :workspaces_lower_slug_idx)
  end

  @doc """
  Changeset for the agent-key pause/resume transition (#231-a).

  Separate from `changeset/2` because pause is a security-state
  flip, not a generic edit. The slug/name `validate_required` from
  the main changeset would reject a pure pause update.
  """
  def pause_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [
      :agent_keys_paused_at,
      :agent_keys_paused_reason,
      :agent_keys_paused_by_user_id
    ])
    |> validate_length(:agent_keys_paused_reason, max: 256)
    |> assoc_constraint(:agent_keys_paused_by_user)
  end

  @doc "True iff this workspace has agent-key auth paused."
  @spec agent_keys_paused?(t()) :: boolean()
  def agent_keys_paused?(%__MODULE__{agent_keys_paused_at: %DateTime{}}), do: true
  def agent_keys_paused?(%__MODULE__{}), do: false

  @doc """
  Changeset for the Base mainnet eligibility flip (#178).

  Separate from `changeset/2` because mainnet enablement is an
  admin-only security decision, not a user-editable workspace
  attribute. The slug/name `validate_required` from `changeset/2`
  would reject a pure mainnet-flag update and the audit posture
  is also different (mainnet flips warrant their own audit
  events, slug renames don't).
  """
  @spec mainnet_changeset(t(), map()) :: Ecto.Changeset.t()
  def mainnet_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:mainnet_enabled])
    |> validate_required([:mainnet_enabled])
  end

  @doc "True iff this workspace has mainnet eligibility explicitly enabled."
  @spec mainnet_enabled?(t()) :: boolean()
  def mainnet_enabled?(%__MODULE__{mainnet_enabled: true}), do: true
  def mainnet_enabled?(%__MODULE__{}), do: false

  @doc """
  Changeset for the `notify_execution_confirmed` opt-in flip
  (#234). Separate from `changeset/2` because notification
  preferences are an admin-only setting flip, not a generic
  workspace edit.
  """
  @spec notification_changeset(t(), map()) :: Ecto.Changeset.t()
  def notification_changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:notify_execution_confirmed])
    |> validate_required([:notify_execution_confirmed])
  end

  @doc "True iff this workspace opts into success-side execution.confirmed notifications."
  @spec notify_execution_confirmed?(t()) :: boolean()
  def notify_execution_confirmed?(%__MODULE__{notify_execution_confirmed: true}), do: true
  def notify_execution_confirmed?(%__MODULE__{}), do: false

  defp normalise_slug(slug) when is_binary(slug),
    do: slug |> String.trim() |> String.downcase()

  defp normalise_slug(other), do: other
end
