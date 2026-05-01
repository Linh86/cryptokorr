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

    has_many :memberships, Membership

    timestamps()
  end

  @doc "Changeset for creating or renaming a workspace."
  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:slug, :name])
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

  defp normalise_slug(slug) when is_binary(slug),
    do: slug |> String.trim() |> String.downcase()

  defp normalise_slug(other), do: other
end
