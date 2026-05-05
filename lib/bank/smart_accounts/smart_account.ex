defmodule Bank.SmartAccounts.SmartAccount do
  @moduledoc """
  Workspace-scoped smart account row (#183, epic #167).

  An explicit domain model for ERC-4337 / kernel smart accounts
  the runtime acts through. Today
  `delegation.smart_account_id` and
  `execution_plan.smart_account_id` are bare opaque strings;
  this schema is the first-class home for the per-account
  state that the multi-account epic depends on.

  ## Lifecycle

    * `:provisioning` (default) — the row is recorded but the
      on-chain account is not yet observable / usable.
      Operator-driven provisioning flips to `:active` once the
      deployment tx is confirmed (handled by the provisioning
      worker that lands in #184/#185).
    * `:active` — the smart account is usable for dispatch.
      `provisioned_at` is set on the transition.
    * `:inactive` — temporarily disabled (e.g. operator paused
      it, or the workspace lost a chain capability). Reversible
      back to `:active`.
    * `:revoked` — terminal. `revoked_at` is set. Cannot be
      reactivated; create a new row instead.

  ## Workspace boundary

  Every read and write at the context layer takes a
  `workspace_id`. There is no global `get/1` that crosses
  workspace boundaries — siblings cannot observe each other's
  smart accounts even by id.

  ## Address normalisation

  Address is lowercased + trimmed at the changeset boundary so
  duplicate detection is reliable across operator typing.
  Checksum-cased input is accepted and normalised; the
  authoritative form on-disk is lowercase. The DB-level unique
  index `(workspace_id, chain, lower(address))` enforces this
  even if a future caller forgets to normalise.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Bank.Accounts.User
  alias Bank.Workspaces.Workspace

  @type t :: %__MODULE__{}

  @statuses ~w(provisioning active inactive revoked)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "smart_accounts" do
    field :chain, :string
    field :address, :string
    field :status, Ecto.Enum, values: @statuses, default: :provisioning
    field :owner_wallet_address, :string
    field :metadata, :map, default: %{}
    field :provisioned_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec

    belongs_to :workspace, Workspace
    belongs_to :owner_user, User, foreign_key: :owner_user_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(workspace_id chain address)a
  @optional ~w(status owner_user_id owner_wallet_address metadata provisioned_at)a

  @doc """
  Build the insert changeset.

  Normalises `address` and `owner_wallet_address` to lowercase
  + trimmed so the unique-index predicate matches operator
  input regardless of casing. `status` defaults to
  `:provisioning` and is only set explicitly by tests / a
  future provisioning worker that wants to record an
  already-provisioned account in one step.
  """
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> normalise_address()
    |> normalise_owner_wallet_address()
    |> normalise_chain()
    |> validate_inclusion(:status, @statuses)
    |> validate_address_format()
    |> validate_chain_present()
    |> unique_constraint([:workspace_id, :chain, :address],
      name: :smart_accounts_workspace_chain_address_uidx,
      message: "has already been taken"
    )
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:owner_user_id)
  end

  @doc """
  Build a status-transition changeset.

  Stamps `provisioned_at` on the `:active` transition (only
  when previously not set, so re-running the transition does
  not move the timestamp), and `revoked_at` on the `:revoked`
  transition (terminal).

  Caller is responsible for refusing transitions out of
  `:revoked` at the context layer; we don't enforce it at the
  schema level so a future replay/repair path can correct a
  mis-revoked row.
  """
  @spec status_changeset(t(), atom(), DateTime.t()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = smart_account, new_status, %DateTime{} = at)
      when new_status in @statuses do
    base =
      smart_account
      |> cast(%{status: new_status}, [:status])
      |> validate_required([:status])

    case new_status do
      :active ->
        if is_nil(smart_account.provisioned_at),
          do: put_change(base, :provisioned_at, at),
          else: base

      :revoked ->
        put_change(base, :revoked_at, at)

      _ ->
        base
    end
  end

  @doc "Statuses recognised by the schema."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  # --- Internal --------------------------------------------------------------

  defp normalise_address(changeset) do
    case get_change(changeset, :address) do
      address when is_binary(address) ->
        put_change(changeset, :address, normalise(address))

      _ ->
        changeset
    end
  end

  defp normalise_owner_wallet_address(changeset) do
    case get_change(changeset, :owner_wallet_address) do
      address when is_binary(address) ->
        put_change(changeset, :owner_wallet_address, normalise(address))

      _ ->
        changeset
    end
  end

  defp normalise_chain(changeset) do
    case get_change(changeset, :chain) do
      chain when is_binary(chain) ->
        put_change(changeset, :chain, chain |> String.trim() |> String.downcase())

      _ ->
        changeset
    end
  end

  # 0x + 40 lower-hex characters. Strict; we accept 0x-prefix
  # only because that is the universal EVM address shape.
  # Operator-supplied checksum casing is normalised away
  # before this validation.
  defp validate_address_format(changeset) do
    case get_field(changeset, :address) do
      address when is_binary(address) ->
        if Regex.match?(~r/\A0x[0-9a-f]{40}\z/, address) do
          changeset
        else
          add_error(changeset, :address, "must be a 0x-prefixed 40-char hex address")
        end

      _ ->
        changeset
    end
  end

  defp validate_chain_present(changeset) do
    case get_field(changeset, :chain) do
      chain when is_binary(chain) and chain != "" ->
        if Regex.match?(~r/\A[a-z0-9_-]{1,32}\z/, chain) do
          changeset
        else
          add_error(changeset, :chain, "must be a kebab-case chain id")
        end

      _ ->
        changeset
    end
  end

  defp normalise(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
end
