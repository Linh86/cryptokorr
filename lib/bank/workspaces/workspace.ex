defmodule Bank.Workspaces.Workspace do
  @moduledoc """
  A unit of product scope (epic #153, issue #155).

  Counterparties, policies, delegations, intents, decisions all
  eventually pivot off `workspace_id` (#158). This module is the
  identity of a workspace; membership and roles live in
  `Bank.Workspaces.Membership`.

  Slugs are normalised to lowercase at the boundary so a functional
  unique index on `lower(slug)` keeps casing consistent.
  """

  use Bank.Schema

  alias Bank.Workspaces.Membership

  @type t :: %__MODULE__{}

  schema "workspaces" do
    field :slug, :string
    field :name, :string

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

  defp normalise_slug(slug) when is_binary(slug),
    do: slug |> String.trim() |> String.downcase()

  defp normalise_slug(other), do: other
end
