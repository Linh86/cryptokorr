defmodule BankWeb.API.V1.WalletBindingsInstallController do
  @moduledoc """
  `/v1/wallet_bindings/:id/install_*` — browser-signed ZeroDev
  permission install endpoints (#474).

  Three actions:

    * `GET  /v1/wallet_bindings/:id/install_envelope` — returns
      Phoenix's canonical install envelope (scope, scope_hash,
      smart-account address, kernel + permissions package
      version, browser-tier bundler URL, session signer
      address). The browser relays the bytes byte-for-byte to the
      ZeroDev SDK; Phoenix is the source of truth.
    * `POST /v1/wallet_bindings/:id/install_attestation` — the
      browser reports each lifecycle step (`submitted | confirmed
      | user_rejected | bundler_rejected | reverted`). On
      `submitted` Phoenix persists a `:pending` delegation row;
      on `confirmed` Phoenix enqueues the on-chain verifier
      worker (Phoenix MUST verify on-chain before marking the row
      `:active`); on any failure Phoenix audits with a category
      atom from the fixed-allowlist.
    * `GET  /v1/wallet_bindings/:id/install_status` — browser
      polls for the current state to drive UI through `awaiting
      → submitted → verifying → active | failed`.

  Auth: `:api_authenticated, :api_operator` — the browser-signed
  install is a workspace-state-advancing action. Workspace
  isolation is enforced via the binding's `workspace_id` matching
  the caller's `current_scope.workspace.id`; cross-workspace ids
  return `404 not_found` per the existing convention so the
  response cannot confirm that a row exists in a sibling tenant.

  Rate limiting rides the standard `:api_authenticated` plug; this
  controller does not add any extra cap.

  See `docs/design/browser-signed-install.md` for the full
  architectural rationale.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Bank.Repo
  alias Bank.SessionPermissions.BrowserInstall
  alias Bank.WalletBindings.WalletBinding
  alias OpenApiSpex.Reference

  @unauthorized_ref %Reference{"$ref": "#/components/responses/Unauthorized"}
  @forbidden_ref %Reference{"$ref": "#/components/responses/Forbidden"}
  @not_found_ref %Reference{"$ref": "#/components/responses/NotFound"}
  @too_many_requests_ref %Reference{"$ref": "#/components/responses/TooManyRequests"}
  @unprocessable_ref %Reference{"$ref": "#/components/responses/UnprocessableEntity"}

  # --- GET /v1/wallet_bindings/:id/install_envelope -----------------------

  operation(:envelope,
    summary: "Get the browser-install envelope for a verified binding",
    description: """
    Returns the canonical install envelope a browser must feed to
    the ZeroDev SDK to build the install UserOperation. Phoenix is
    the source of truth for the scope; the response carries the
    scope JSON verbatim plus a `scope_hash` audit anchor.

    Refused with `404 not_found` if the binding does not exist or
    belongs to a different workspace, `422 unsupported_chain` if
    the binding's `chain_id` is not Base Sepolia (84532),
    `422 binding_not_verified` if the binding has not completed
    the EIP-191 verify step, `422 binding_revoked` if the binding
    has been revoked, `422 runtime_paused` / `422 workspace_paused`
    if the runtime / workspace is paused.

    Emits a `delegation.install_envelope_issued` audit event on
    every successful return (including idempotent re-fetches by
    the same caller).
    """,
    tags: ["WalletBindings"],
    parameters: [
      id: [in: :path, description: "Wallet binding id (UUID)", schema: :string]
    ],
    responses: %{
      200 =>
        {"Install envelope", "application/json", BankWeb.OpenApi.Schemas.InstallEnvelopeResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      404 => @not_found_ref,
      422 => @unprocessable_ref,
      429 => @too_many_requests_ref
    }
  )

  def envelope(conn, %{"id" => binding_id}) do
    workspace_id = workspace_id!(conn)

    with {:ok, binding} <- load_binding(binding_id, workspace_id),
         {:ok, envelope} <- BrowserInstall.build_envelope(workspace_id, binding) do
      json(conn, envelope_payload(envelope))
    else
      {:error, :not_found} -> not_found(conn)
      {:error, refusal} -> refusal_response(conn, refusal)
    end
  end

  # --- POST /v1/wallet_bindings/:id/install_attestation -------------------

  operation(:attestation,
    summary: "Record a browser-signed install attestation",
    description: """
    The browser reports each lifecycle step. Phoenix never marks
    the delegation `:active` from a `confirmed` attestation alone
    — it enqueues `Bank.Runtime.Workers.VerifyInstallOnchain`
    which reads the kernel's installed validators directly.

    `status` is one of `submitted | confirmed | user_rejected |
    bundler_rejected | reverted`. Status-specific required
    fields are documented in the request schema.

    Reason categories for failure statuses are pinned to a fixed
    allowlist; anything else collapses to `unknown`. Free-form
    upstream strings never reach the audit row or the
    delegation's `last_reason` column.
    """,
    tags: ["WalletBindings"],
    parameters: [
      id: [in: :path, description: "Wallet binding id (UUID)", schema: :string]
    ],
    request_body:
      {"Install attestation", "application/json",
       BankWeb.OpenApi.Schemas.InstallAttestationRequest},
    responses: %{
      202 =>
        {"Attestation recorded", "application/json",
         BankWeb.OpenApi.Schemas.InstallAttestationResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      404 => @not_found_ref,
      422 => @unprocessable_ref,
      429 => @too_many_requests_ref
    }
  )

  def attestation(conn, %{"id" => binding_id} = params) do
    workspace_id = workspace_id!(conn)

    with {:ok, binding} <- load_binding(binding_id, workspace_id),
         {:ok, %{state: state, delegation: delegation}} <-
           BrowserInstall.record_attestation(workspace_id, binding, params) do
      conn
      |> put_status(:accepted)
      |> json(%{
        state: Atom.to_string(state),
        delegation_id: maybe_id(delegation)
      })
    else
      {:error, :not_found} -> not_found(conn)
      {:error, refusal} -> refusal_response(conn, refusal)
    end
  end

  # --- GET /v1/wallet_bindings/:id/install_status -------------------------

  operation(:status,
    summary: "Read the current install state for a binding",
    description: """
    Returns one of `awaiting | submitted | verifying | active |
    failed`. `awaiting` = no attestation reported yet for this
    binding; `submitted` = browser reported `submitted` but no
    bundler receipt yet; `verifying` = browser reported
    `confirmed`, on-chain verifier worker enqueued / running;
    `active` = on-chain verifier passed; `failed` = terminal
    failure with a category atom on the row's `last_reason`.

    Same auth + workspace-isolation posture as the other two
    endpoints.
    """,
    tags: ["WalletBindings"],
    parameters: [
      id: [in: :path, description: "Wallet binding id (UUID)", schema: :string]
    ],
    responses: %{
      200 =>
        {"Install status", "application/json", BankWeb.OpenApi.Schemas.InstallStatusResponse},
      401 => @unauthorized_ref,
      403 => @forbidden_ref,
      404 => @not_found_ref,
      422 => @unprocessable_ref,
      429 => @too_many_requests_ref
    }
  )

  def status(conn, %{"id" => binding_id}) do
    workspace_id = workspace_id!(conn)

    case load_binding(binding_id, workspace_id) do
      {:ok, binding} ->
        report = BrowserInstall.status(workspace_id, binding)

        json(conn, %{
          state: Atom.to_string(report.state),
          delegation_id: maybe_id(report.delegation),
          last_reason: maybe_last_reason(report.delegation)
        })

      {:error, :not_found} ->
        not_found(conn)
    end
  end

  # --- internal helpers ---------------------------------------------------

  defp workspace_id!(%Plug.Conn{} = conn) do
    conn.assigns.current_scope.workspace.id
  end

  defp load_binding(binding_id, workspace_id) when is_binary(binding_id) do
    case Ecto.UUID.cast(binding_id) do
      {:ok, uuid} ->
        case Repo.get(WalletBinding, uuid) do
          %WalletBinding{workspace_id: ^workspace_id} = binding -> {:ok, binding}
          _ -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp envelope_payload(envelope) do
    Map.take(envelope, [
      :binding_id,
      :smart_account_id,
      :chain_id,
      :entry_point_address,
      :kernel_version,
      :permissions_package_version,
      :session_signer_address,
      :scope,
      :scope_hash,
      :bundler_rpc_url,
      :human_readable_summary
    ])
  end

  defp maybe_id(nil), do: nil
  defp maybe_id(%{id: id}), do: id

  defp maybe_last_reason(nil), do: nil
  defp maybe_last_reason(%{last_reason: r}), do: r

  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found"}})
  end

  defp refusal_response(conn, refusal) do
    {status, code, message} = refusal_to_http(refusal)

    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp refusal_to_http(:workspace_mismatch),
    do: {:not_found, "not_found", nil}

  defp refusal_to_http(:binding_not_verified),
    do:
      {:unprocessable_entity, "binding_not_verified",
       "wallet binding has not completed EIP-191 verify"}

  defp refusal_to_http(:binding_revoked),
    do: {:unprocessable_entity, "binding_revoked", "wallet binding was revoked"}

  defp refusal_to_http(:unsupported_chain),
    do: {:unprocessable_entity, "unsupported_chain", "binding chain is not Base Sepolia (84532)"}

  defp refusal_to_http(:runtime_paused),
    do: {:unprocessable_entity, "runtime_paused", "runtime is paused"}

  defp refusal_to_http(:workspace_paused),
    do: {:unprocessable_entity, "workspace_paused", "workspace is paused"}

  defp refusal_to_http({:invalid_attestation, detail}),
    do:
      {:unprocessable_entity, "invalid_attestation",
       "invalid attestation payload: #{inspect(detail)}"}

  defp refusal_to_http({:invalid_status, status}),
    do: {:unprocessable_entity, "invalid_status", "unsupported attestation status: #{status}"}

  defp refusal_to_http(_other),
    do: {:unprocessable_entity, "invalid_attestation", "attestation rejected"}
end
