defmodule BankWeb.API.V1.APIKeyController do
  @moduledoc """
  `/v1/api_keys` — workspace-scoped API key management (#218c).

  Endpoints:

    * `GET    /v1/api_keys`       — list (active + revoked, newest first)
    * `POST   /v1/api_keys`       — mint a new key (raw secret in body once)
    * `DELETE /v1/api_keys/:id`   — soft-revoke

  ## Auth + role gate

  Every endpoint sits behind `:api_authenticated` + `:api_admin`
  (see `BankWeb.Router`). Only `:admin` and `:owner` keys reach
  this controller. The role gate fails closed earlier; the
  controller does NOT re-check it.

  ## Workspace scope

  All three endpoints scope by `current_scope.workspace.id`:
  `index/2` filters to that workspace, `create/2` stamps the new
  row with that workspace, and `delete/2` resolves the path id
  through `Bank.APIKeys.get_workspace_key/2` so an admin in
  workspace A cannot revoke a key in workspace B.

  ## Creator privilege

  `create/2` enforces `Membership.role_at_least?(creator_role,
  requested_role)`. An admin can mint viewer / operator / admin
  keys but NOT owner keys; an owner can mint any role. This
  closes the deferral documented on `Bank.APIKeys.create_key/4`
  in #218a — the context primitive trusts its caller, so the
  caller MUST be the controller, where the gate runs.

  ## Duplicate names are allowed by design

  Two keys can carry the same `name` within a workspace. The
  prefix + secret are the unique identifiers; `name` is just a
  human label. Allowing duplicates supports a common operator
  workflow: rotation by minting a fresh `ci-runner` alongside
  the old one, switching consumers, then revoking the old key.
  Forcing uniqueness would push operators to invent rotation
  suffixes (`ci-runner-2`, `ci-runner-v3`) that drift from the
  meaningful label.

  ## Audit actor for issued keys

  When the request is itself authenticated by an API key
  (machine caller, `current_scope.user == nil`), `create/2`
  attributes the `api_key.created` audit event to the calling
  key's original `created_by_user_id` — the human who minted
  the *calling* key. This keeps every issued key chained back
  to a real human in the audit trail even when keys are minted
  via a script using a service-account-style management key.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Bank.APIKeys
  alias Bank.Workspaces.Membership
  alias BankWeb.API.V1.APIKeyJSON
  alias OpenApiSpex.{Parameter, Reference}

  @id_ref %Reference{"$ref": "#/components/schemas/Id"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @idempotency_key_ref %Reference{"$ref": "#/components/parameters/IdempotencyKey"}
  @unauthorized_ref %Reference{"$ref": "#/components/responses/Unauthorized"}
  @forbidden_ref %Reference{"$ref": "#/components/responses/Forbidden"}
  @not_found_ref %Reference{"$ref": "#/components/responses/NotFound"}
  @unprocessable_ref %Reference{"$ref": "#/components/responses/UnprocessableEntity"}
  @too_many_requests_ref %Reference{"$ref": "#/components/responses/TooManyRequests"}

  @api_key_id_param %Parameter{
    name: :id,
    in: :path,
    required: true,
    description: "API key id (UUID).",
    schema: @id_ref
  }

  # --- GET /v1/api_keys -----------------------------------------------------

  operation(:index,
    summary: "List API keys for the current workspace",
    description: """
    Returns the workspace's API keys (active + revoked) ordered
    newest first. The raw secret is NEVER included — this surface
    only renders the public prefix and metadata.
    """,
    tags: ["APIKeys"],
    parameters: [@request_id_in_ref],
    responses: %{
      ok: {"API key list", "application/json", BankWeb.OpenApi.Schemas.APIKeyListResponse},
      unauthorized: @unauthorized_ref,
      forbidden: @forbidden_ref,
      too_many_requests: @too_many_requests_ref
    }
  )

  def index(conn, _params) do
    keys = APIKeys.list_keys_with_creator(conn.assigns.current_scope.workspace.id)

    conn
    |> put_status(:ok)
    |> json(APIKeyJSON.index(%{keys: keys}))
  end

  # --- POST /v1/api_keys ----------------------------------------------------

  operation(:create,
    summary: "Mint a new API key",
    description: """
    Creates a new workspace-scoped, role-bound API key. The
    response body includes `raw_key` — the on-the-wire credential.
    It is shown EXACTLY ONCE; persist it immediately.

    The caller's role must be greater than or equal to the
    requested `role` under the hierarchy `viewer < operator <
    admin < owner`. Attempting to mint a key stronger than the
    caller produces `403 forbidden_role_above_creator`.
    """,
    tags: ["APIKeys"],
    parameters: [@idempotency_key_ref, @request_id_in_ref],
    request_body:
      {"API key create body", "application/json", BankWeb.OpenApi.Schemas.APIKeyCreateRequest},
    responses: %{
      created:
        {"Newly minted API key (raw_key shown once)", "application/json",
         BankWeb.OpenApi.Schemas.APIKeyCreatedResponse},
      unauthorized: @unauthorized_ref,
      forbidden: @forbidden_ref,
      too_many_requests: @too_many_requests_ref,
      unprocessable_entity: @unprocessable_ref
    }
  )

  def create(conn, params) do
    scope = conn.assigns.current_scope

    with {:ok, role} <- parse_role(params),
         {:ok, name} <- parse_name(params),
         :ok <- enforce_creator_role(scope.role, role),
         {:ok, expires_at} <- parse_expires_at(params),
         {:ok, creator} <- resolve_creator(scope) do
      opts =
        if expires_at, do: [expires_at: expires_at], else: []

      case APIKeys.create_key(scope.workspace, creator, role, name, opts) do
        {:ok, key, raw_secret} ->
          conn
          |> put_status(:created)
          |> json(APIKeyJSON.created(%{key: key, raw_key: raw_secret}))

        {:error, _changeset} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: %{code: "invalid_body"}})
      end
    else
      {:error, :forbidden_role_above_creator} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{code: "forbidden_role_above_creator"}})

      {:error, :no_creator_user} ->
        # The current scope was authenticated by an API key minted
        # by a user that no longer exists — schema FK :restrict
        # should prevent this in practice, but guard anyway. The
        # creator user is required as the audit actor.
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{code: "creator_user_unavailable"}})

      {:error, code} when is_binary(code) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: code}})
    end
  end

  # --- POST /v1/api_keys/:id/rotate ----------------------------------------

  operation(:rotate,
    summary: "Rotate an API key",
    description: """
    Atomically replaces an active API key with a fresh one
    carrying the same `workspace_id`, `role`, `name`, and
    `expires_at`. The old key is revoked immediately — there is no
    grace period in v0.1; consumers must switch to the new
    `raw_key` synchronously. Operators who need overlap should
    `create + revoke` manually (duplicate names are allowed).

    Response includes the new `raw_key` shown EXACTLY ONCE.

    Failure modes:

      * `404 not_found` — id unknown OR belongs to another
        workspace (cross-workspace rotation is invisible).
      * `422 already_revoked` — the key was already revoked (or
        another rotation won the race; see the context module
        for the concurrency contract).
    """,
    tags: ["APIKeys"],
    parameters: [@api_key_id_param, @idempotency_key_ref, @request_id_in_ref],
    responses: %{
      created:
        {"Newly minted replacement key (raw_key shown once)", "application/json",
         BankWeb.OpenApi.Schemas.APIKeyCreatedResponse},
      unauthorized: @unauthorized_ref,
      forbidden: @forbidden_ref,
      too_many_requests: @too_many_requests_ref,
      not_found: @not_found_ref,
      unprocessable_entity: @unprocessable_ref
    }
  )

  def rotate(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {:ok, old_key} <- APIKeys.get_workspace_key(scope.workspace.id, id),
         # Creator-privilege parity with `create/2`: an admin caller
         # cannot rotate an `:owner` key, otherwise rotation becomes a
         # back door for refreshing a credential the caller could not
         # mint via `create/2`. Mirrors the role gate at line 140.
         :ok <- enforce_creator_role(scope.role, old_key.role),
         {:ok, actor} <- resolve_creator(scope),
         {:ok, new_key, raw_secret} <- APIKeys.rotate_key(old_key, actor) do
      conn
      |> put_status(:created)
      |> json(APIKeyJSON.created(%{key: new_key, raw_key: raw_secret}))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found"}})

      {:error, :forbidden_role_above_creator} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{code: "forbidden_role_above_creator"}})

      {:error, :already_revoked} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "already_revoked"}})

      {:error, :no_creator_user} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{code: "creator_user_unavailable"}})

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "rotate_failed"}})
    end
  end

  # --- DELETE /v1/api_keys/:id ---------------------------------------------

  operation(:delete,
    summary: "Soft-revoke an API key",
    description: """
    Sets `revoked_at` on the key and emits the
    `api_key.revoked` audit event. Idempotent — calling on an
    already-revoked key returns 200 without re-emitting the
    audit event.
    """,
    tags: ["APIKeys"],
    parameters: [@api_key_id_param, @request_id_in_ref],
    responses: %{
      ok: {"Revoked key", "application/json", BankWeb.OpenApi.Schemas.APIKeyEntity},
      unauthorized: @unauthorized_ref,
      forbidden: @forbidden_ref,
      too_many_requests: @too_many_requests_ref,
      not_found: @not_found_ref
    }
  )

  def delete(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    with {:ok, key} <- APIKeys.get_workspace_key(scope.workspace.id, id),
         {:ok, creator} <- resolve_creator(scope),
         {:ok, revoked} <- APIKeys.revoke_key(key, actor: creator) do
      conn
      |> put_status(:ok)
      |> json(APIKeyJSON.revoked(%{key: revoked}))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: %{code: "not_found"}})

      {:error, :no_creator_user} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: %{code: "creator_user_unavailable"}})

      {:error, _other} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "revoke_failed"}})
    end
  end

  # --- private --------------------------------------------------------------

  defp parse_role(%{"role" => role}) when role in ["viewer", "operator", "admin", "owner"],
    do: {:ok, String.to_existing_atom(role)}

  defp parse_role(_), do: {:error, "invalid_role"}

  defp parse_name(%{"name" => name}) when is_binary(name) do
    name = String.trim(name)
    if String.length(name) in 1..255, do: {:ok, name}, else: {:error, "invalid_name"}
  end

  defp parse_name(_), do: {:error, "invalid_name"}

  defp parse_expires_at(%{"expires_at" => nil}), do: {:ok, nil}
  defp parse_expires_at(%{"expires_at" => ""}), do: {:ok, nil}

  defp parse_expires_at(%{"expires_at" => v}) when is_binary(v) do
    with {:ok, dt, _} <- DateTime.from_iso8601(v),
         :ok <- ensure_future(dt) do
      {:ok, dt}
    else
      :past -> {:error, "invalid_expires_at"}
      _ -> {:error, "invalid_expires_at"}
    end
  end

  defp parse_expires_at(_), do: {:ok, nil}

  # Reject past timestamps at create time. The auth plug already
  # rejects expired keys at use-time, but accepting a past value
  # here would produce a freshly-minted key that fails on first
  # auth — pure operator footgun, plus an attribution-cleanliness
  # issue (the new row looks "expired" instantly).
  defp ensure_future(%DateTime{} = dt) do
    if DateTime.compare(dt, DateTime.utc_now()) == :gt, do: :ok, else: :past
  end

  defp enforce_creator_role(creator_role, requested_role) do
    if Membership.role_at_least?(creator_role, requested_role) do
      :ok
    else
      {:error, :forbidden_role_above_creator}
    end
  end

  # The audit `actor_id` for `api_key.created` is the creating
  # user's id. When the request is itself authenticated by an API
  # key, the request's `current_scope.user` is `nil` (machine
  # caller), so we attribute the new key to the calling key's
  # original creator user. This keeps every issued key chained
  # back to a real human in the audit trail.
  defp resolve_creator(%{user: %Bank.Accounts.User{} = user}), do: {:ok, user}

  defp resolve_creator(%{api_key: %Bank.APIKeys.APIKey{} = api_key}) do
    case Bank.Accounts.get_user(api_key.created_by_user_id) do
      %Bank.Accounts.User{} = user -> {:ok, user}
      _ -> {:error, :no_creator_user}
    end
  end

  defp resolve_creator(_), do: {:error, :no_creator_user}
end
