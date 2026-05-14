defmodule BankWeb.WalletBindingsInstallController do
  @moduledoc """
  Browser-session-authenticated install endpoints for the
  ZeroDev permission install flow (#500).

  Sibling of `BankWeb.API.V1.WalletBindingsInstallController`,
  which serves the same operations behind API-key auth on the
  `/v1/...` surface (Path B). Both controllers share the same
  context module (`Bank.SessionPermissions.BrowserInstall`); the
  only difference is the auth posture:

    * `/v1/wallet_bindings/:id/install_*` — `Authorization: Bearer
      cb_<...>` API key + role gate. Used by curl, SDKs, CI.
    * `/wallet_bindings/:id/install_*` (this controller) —
      operator-console session cookie populated by
      `BankWeb.Plugs.FetchCurrentUser`, plus CSRF on the
      attestation POST via the `:browser` pipeline's
      `:protect_from_forgery`. Used by the browser hook so an
      operator does not have to mint and embed an API key into
      their browser to drive an install.

  ## Endpoints

    * `GET  /wallet_bindings/:id/install_envelope` — viewer+.
      Mirrors the `/v1` envelope payload (same context call,
      same JSON shape). Anonymous → 401, no workspace → 403,
      cross-workspace binding id → 404.
    * `GET  /wallet_bindings/:id/install_status` — viewer+. Same
      shape as the `/v1` status response.
    * `POST /wallet_bindings/:id/install_attestation` — operator+.
      Role-gated AND CSRF-protected (the route lives under the
      `:browser` pipeline which runs `:protect_from_forgery`). The
      browser MUST send the per-session CSRF token in the
      `x-csrf-token` header; otherwise Plug's
      `Plug.CSRFProtection.InvalidCSRFTokenError` raises which
      `Plug` translates to a 422.

  ## Workspace isolation

  Cross-workspace `:id` returns `404 not_found` per the same
  convention used by every workspace-scoped read in the codebase.
  The response body never confirms a row exists in a sibling
  tenant.

  ## What this module does NOT do

    * No server-side signing. The attestation POST records what
      the browser observed; it does NOT call adapter-side
      grant-delegation paths.
    * No decision-pipeline mutation. The install flow only writes
      delegation rows + audit events; transfers/swaps/Morpho are
      untouched.
    * No bundler / RPC URL is read here. The poller worker
      (`Bank.Runtime.Workers.PollInstallReceipt`) handles bundler
      I/O; this controller is a thin auth+routing layer over
      `Bank.SessionPermissions.BrowserInstall`.
  """

  use BankWeb, :controller

  alias Bank.AdapterClient
  alias Bank.Repo
  alias Bank.SessionPermissions.BrowserInstall
  alias Bank.WalletBindings.WalletBinding
  alias Bank.Workspaces.Membership

  # --- GET /wallet_bindings/:id/install_envelope -----------------------

  def envelope(conn, %{"id" => binding_id}) do
    with :ok <- require_role(conn, :viewer),
         workspace_id = workspace_id!(conn),
         {:ok, binding} <- load_binding(binding_id, workspace_id),
         {:ok, envelope} <- BrowserInstall.build_envelope(workspace_id, binding) do
      json(conn, envelope_payload(envelope))
    else
      {:error, :unauthenticated} -> unauthenticated(conn)
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, refusal} -> refusal_response(conn, refusal)
    end
  end

  # --- GET /wallet_bindings/:id/install_status -------------------------

  def status(conn, %{"id" => binding_id}) do
    with :ok <- require_role(conn, :viewer),
         workspace_id = workspace_id!(conn),
         {:ok, binding} <- load_binding(binding_id, workspace_id) do
      report = BrowserInstall.status(workspace_id, binding)

      json(conn, %{
        state: Atom.to_string(report.state),
        delegation_id: maybe_id(report.delegation),
        last_reason: maybe_last_reason(report.delegation)
      })
    else
      {:error, :unauthenticated} -> unauthenticated(conn)
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
    end
  end

  # --- POST /wallet_bindings/:id/install_attestation -------------------

  def attestation(conn, %{"id" => binding_id} = params) do
    with :ok <- require_role(conn, :operator),
         workspace_id = workspace_id!(conn),
         {:ok, binding} <- load_binding(binding_id, workspace_id),
         {:ok, %{state: state, delegation: delegation}} <-
           BrowserInstall.record_attestation(workspace_id, binding, params) do
      conn
      |> put_status(:accepted)
      |> json(%{
        state: Atom.to_string(state),
        delegation_id: maybe_id(delegation)
      })
    else
      {:error, :unauthenticated} -> unauthenticated(conn)
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, refusal} -> refusal_response(conn, refusal)
    end
  end

  # --- POST /wallet_bindings/:id/sign_install_userop_hash --------------
  #
  # Proxy for the install UserOp's permission-validator signature.
  # The browser-driven install needs TWO signatures on the install
  # UserOp:
  #
  #   1. Sudo (user's MetaMask) signs the enable typed-data — done
  #      in-browser via `personal_sign`.
  #   2. Permission validator (operator's session signer) signs the
  #      EIP-4337 UserOp hash — that key (`DELEGATION_SIGNER_KEY`)
  #      lives on chain_adapter; the browser cannot sign locally.
  #
  # The browser asks Phoenix; Phoenix authenticates the user,
  # validates the binding belongs to their workspace, sanity-checks
  # the hash shape, and forwards to chain_adapter via the
  # operator-internal bearer secret. The signature comes back; the
  # browser embeds it in the install UserOp before calling the
  # bundler.
  #
  # Refusal posture:
  #   * Anonymous / wrong workspace → 401 / 403 / 404 (no
  #     existence-leak across workspaces).
  #   * Binding revoked / unverified / on wrong chain →
  #     `kernel_account_collision`/`binding_revoked`/etc. mapped to
  #     a 422 with the controller's existing refusal vocabulary.
  #   * Malformed hash → 422 `invalid_user_op_hash`.
  #   * Adapter down / 5xx → 502 `session_signer_unavailable` so
  #     the JS hook can render the precise operator-actionable copy
  #     (different from `bundler_unavailable`).
  #   * Adapter 4xx → 422 `session_signer_refused` (programmer
  #     error: misrouted key, wrong session_signer_address, etc.).
  #
  # The signature is the ONLY value returned. The adapter's private
  # key never crosses this boundary; the bearer secret to the
  # adapter is server-side config and never echoed.
  def sign_install_userop_hash(conn, %{"id" => binding_id} = params) do
    with :ok <- require_role(conn, :operator),
         workspace_id = workspace_id!(conn),
         {:ok, binding} <- load_binding(binding_id, workspace_id),
         :ok <- require_verified_binding(binding),
         {:ok, user_op_hash} <- parse_user_op_hash(params),
         {:ok, expected_session_signer} <-
           validate_session_signer_match(
             params,
             BrowserInstall.configured_session_signer_address()
           ),
         {:ok, result} <-
           AdapterClient.sign_install_session_portion(%{
             binding_id: binding.id,
             smart_account_id: Bank.SessionPermissions.compute_smart_account_id(binding),
             user_op_hash: user_op_hash,
             session_signer_address: expected_session_signer
           }) do
      # Only the signature crosses this boundary. The adapter also
      # returns `session_signer_address` so the browser can run a
      # last-mile consistency check against the install envelope;
      # nothing else from the adapter response is exposed.
      json(conn, %{
        signature: result.signature,
        session_signer_address: result.session_signer_address
      })
    else
      {:error, :unauthenticated} -> unauthenticated(conn)
      {:error, :forbidden} -> forbidden(conn)
      {:error, :not_found} -> not_found(conn)
      {:error, {:invalid_param, code, message}} -> invalid_param(conn, code, message)
      {:error, :adapter_unavailable} -> session_signer_unavailable(conn)
      {:error, {:adapter_rejected, _status, _body}} -> session_signer_refused(conn)
      {:error, {:adapter_error, _status, _body}} -> session_signer_unavailable(conn)
      {:error, :invalid_response} -> session_signer_unavailable(conn)
      {:error, refusal} -> refusal_response(conn, refusal)
    end
  end

  # --- internal helpers -------------------------------------------------

  # Browser-session role check. Anonymous → 401; authenticated
  # without a resolved workspace → 403; role below the requirement
  # → 403. The browser hook handles 401/403 explicitly so we
  # return JSON (the operator console redirects on its own elsewhere
  # via LiveAuth on_mount; these endpoints are XHR-only).
  defp require_role(conn, required) when required in [:viewer, :operator, :admin, :owner] do
    case conn.assigns[:current_scope] do
      nil ->
        {:error, :unauthenticated}

      %{user: nil} ->
        {:error, :unauthenticated}

      %{workspace: nil} ->
        {:error, :forbidden}

      %{role: role} ->
        if Membership.role_at_least?(role, required), do: :ok, else: {:error, :forbidden}
    end
  end

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

  # Mirrors the `/v1` envelope payload exactly so the browser can
  # use the same response shape regardless of which surface it
  # called.
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
      :chain_rpc_url,
      :kernel_account_index,
      :human_readable_summary
    ])
  end

  defp maybe_id(nil), do: nil
  defp maybe_id(%{id: id}), do: id

  defp maybe_last_reason(nil), do: nil
  defp maybe_last_reason(%{last_reason: r}), do: r

  # The binding must be verified AND not revoked before Phoenix
  # will proxy a signing request. Without this gate, a freshly-
  # issued (unverified) or revoked binding could ask the adapter
  # to sign UserOps that would either fail on-chain or produce
  # signed material for a binding the operator already disowned.
  defp require_verified_binding(%WalletBinding{verified_at: nil}),
    do: {:error, :binding_not_verified}

  defp require_verified_binding(%WalletBinding{revoked_at: revoked_at})
       when not is_nil(revoked_at),
       do: {:error, :binding_revoked}

  defp require_verified_binding(%WalletBinding{chain_id: 84_532}), do: :ok
  defp require_verified_binding(%WalletBinding{}), do: {:error, :unsupported_chain}

  # Wire-shape gate for the user_op_hash. The hash is the
  # ERC-4337 v0.7 UserOperation hash the SDK passed to
  # `signMessage`; it MUST be a 0x-prefixed 32-byte hex (66
  # chars). Anything else is either a programmer error or a
  # tampered request — reject with a deterministic code.
  defp parse_user_op_hash(%{"user_op_hash" => hash})
       when is_binary(hash) do
    if Regex.match?(~r/^0x[0-9a-fA-F]{64}$/, hash) do
      {:ok, hash}
    else
      {:error,
       {:invalid_param, "invalid_user_op_hash", "user_op_hash must be 0x-prefixed 32-byte hex"}}
    end
  end

  defp parse_user_op_hash(_),
    do: {:error, {:invalid_param, "invalid_user_op_hash", "user_op_hash is required"}}

  # When the browser includes its envelope's `session_signer_address`,
  # cross-check it against Phoenix's configured value before forwarding
  # to the adapter. This prevents a stale browser session (cached
  # envelope from before a `SESSION_SIGNER_ADDRESS` rotation) from
  # quietly asking the adapter to sign with a different key than
  # what Phoenix's envelope path advertises. Case-insensitive
  # comparison; nil from the client means "trust Phoenix's config"
  # and we pass nil through.
  defp validate_session_signer_match(%{"session_signer_address" => browser_addr}, configured)
       when is_binary(browser_addr) and is_binary(configured) do
    if String.downcase(browser_addr) == String.downcase(configured) do
      {:ok, configured}
    else
      {:error,
       {:invalid_param, "session_signer_mismatch",
        "browser session signer address does not match Phoenix configuration"}}
    end
  end

  defp validate_session_signer_match(%{"session_signer_address" => _}, nil),
    do: {:error, :rpc_not_configured}

  defp validate_session_signer_match(_, configured), do: {:ok, configured}

  defp invalid_param(conn, code, message) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: code, message: message}})
  end

  defp session_signer_unavailable(conn) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{
      error: %{
        code: "session_signer_unavailable",
        message: "the operator session signer is currently unreachable; retry shortly"
      }
    })
  end

  defp session_signer_refused(conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{
      error: %{
        code: "session_signer_refused",
        message: "the operator session signer refused to sign this request"
      }
    })
  end

  defp unauthenticated(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: %{code: "unauthenticated"}})
  end

  defp forbidden(conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: %{code: "forbidden"}})
  end

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

  # Same refusal vocabulary as the `/v1` controller.
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

  # The connected user EOA equals `OPERATOR_ADDRESS` AND the
  # browser kernel index equals the operator kernel index — the
  # derived smart account would be the already-deployed operator
  # account and the install UserOp would revert
  # `AA23 reverted 0x756688fe` (Kernel `InvalidSignature()`). The
  # reason code is exactly the wire-allowlisted atom so the JS
  # hook's `fetchInstallEnvelope` error path forwards it to
  # `parse_install_failure_reason` unchanged.
  defp refusal_to_http(:kernel_account_collision),
    do:
      {:unprocessable_entity, "kernel_account_collision",
       "this wallet would target the operator's smart account; raise BROWSER_KERNEL_ACCOUNT_INDEX or use a different EOA"}

  defp refusal_to_http({:invalid_attestation, detail}),
    do:
      {:unprocessable_entity, "invalid_attestation",
       "invalid attestation payload: #{inspect(detail)}"}

  defp refusal_to_http({:invalid_status, status}),
    do: {:unprocessable_entity, "invalid_status", "unsupported attestation status: #{status}"}

  defp refusal_to_http(_other),
    do: {:unprocessable_entity, "invalid_attestation", "attestation rejected"}
end
