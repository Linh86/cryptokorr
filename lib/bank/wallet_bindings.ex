defmodule Bank.WalletBindings do
  @moduledoc """
  Context: bind a connected EOA wallet to the MVP workspace/user pair.

  The flow:

      1. issue_challenge/3 — server picks a fresh nonce and persists a
         pending challenge row with a short TTL (default 5 minutes).
         The full EIP-191 message is stored so audit + replay can
         re-derive what the wallet authorized.
      2. The browser signs the message via `personal_sign`.
      3. verify_and_bind/2 — server recovers the signing address from
         the signature, compares against the row's expected address,
         and stamps `verified_at` on success.

  The signature itself is never persisted, never logged. Only
  structured failure reasons surface from the verify path.

  ## What this context is NOT

  Not a smart-account install path (#171), not a SIWE/auth-token
  issuer, not a multi-account selector. It only proves "this EOA
  signed for this workspace at this moment", which is the foundation
  the delegation install builds on.
  """

  import Ecto.Query, warn: false

  alias Bank.Audit
  alias Bank.Repo
  alias Bank.WalletBindings.{Signature, WalletBinding}

  # 5-minute challenge TTL is the MVP. Long enough for a hardware-wallet
  # confirmation pause, short enough that a leaked challenge has no
  # meaningful window.
  @default_ttl_seconds 300

  # Base Sepolia is the only chain the MVP wallet binding accepts.
  @supported_chain_ids [84_532]

  @doc """
  Issue a fresh binding challenge for `workspace_id`/`user_id` over
  the connected `address` on `chain_id`. Returns the persisted
  `WalletBinding` row in pending state, ready to be pushed to the
  browser hook.

  Audits `wallet_binding.challenge_issued`. The audit payload carries
  address, chain id, workspace id, expires_at — never the nonce and
  never the signed message.
  """
  @spec issue_challenge(Ecto.UUID.t(), Ecto.UUID.t() | nil, %{
          address: String.t(),
          chain_id: integer()
        }) ::
          {:ok, WalletBinding.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def issue_challenge(workspace_id, user_id, %{address: address, chain_id: chain_id})
      when is_binary(workspace_id) and is_binary(address) and is_integer(chain_id) do
    cond do
      chain_id not in @supported_chain_ids ->
        {:error, :chain_not_supported}

      not valid_address?(address) ->
        {:error, :invalid_address}

      true ->
        normalized = String.downcase(address)
        nonce = generate_nonce()
        now = DateTime.utc_now()
        expires_at = DateTime.add(now, @default_ttl_seconds, :second)

        message =
          build_message(%{
            workspace_id: workspace_id,
            address: normalized,
            chain_id: chain_id,
            nonce: nonce,
            issued_at: now,
            expires_at: expires_at
          })

        attrs = %{
          workspace_id: workspace_id,
          user_id: user_id,
          address: normalized,
          chain_id: chain_id,
          nonce: nonce,
          challenge_message: message,
          expires_at: expires_at
        }

        with {:ok, binding} <-
               attrs
               |> WalletBinding.challenge_changeset()
               |> Repo.insert(),
             {:ok, _ev} <- emit_audit(:challenge_issued, binding, user_id) do
          {:ok, binding}
        end
    end
  end

  @doc """
  Verify a signed challenge and mark the binding active.

  Rejects, with an audit event for each, the cases the prompt calls
  out:

    * `:not_found`               — no row with this id
    * `:already_verified`        — verify_at was already stamped
    * `:revoked`                 — binding has been revoked
    * `:expired`                 — challenge ttl elapsed before verify
    * `:address_mismatch`        — recovered EOA differs from candidate
    * `:malformed_signature`     — signature is not 65 bytes / not hex
    * `:invalid_signature`       — recovery itself failed
    * `:invalid_recovery_id`     — `v` byte is not 27/28/0/1

  The signature is never persisted; failure audits carry only the
  structured reason atom.
  """
  @spec verify_and_bind(Ecto.UUID.t(), String.t()) ::
          {:ok, WalletBinding.t()} | {:error, atom()} | {:error, Ecto.Changeset.t()}
  def verify_and_bind(challenge_id, signature)
      when is_binary(challenge_id) and is_binary(signature) do
    case Repo.get(WalletBinding, challenge_id) do
      nil ->
        emit_failure_audit(:not_found, %{challenge_id: challenge_id})
        {:error, :not_found}

      %WalletBinding{revoked_at: %DateTime{}} = binding ->
        emit_failure_audit(:revoked, binding)
        {:error, :revoked}

      %WalletBinding{verified_at: %DateTime{}} = binding ->
        emit_failure_audit(:already_verified, binding)
        {:error, :already_verified}

      %WalletBinding{} = binding ->
        do_verify(binding, signature)
    end
  end

  @doc """
  Return the currently bound EOA for `workspace_id`, or `nil`.

  "Currently bound" = verified, not revoked. Picks the most recent
  verified row when several exist (e.g. the workspace re-bound a
  fresh address). Designed for the #170 status UI.
  """
  @spec get_active_binding(Ecto.UUID.t()) :: WalletBinding.t() | nil
  def get_active_binding(workspace_id) when is_binary(workspace_id) do
    from(b in WalletBinding,
      where:
        b.workspace_id == ^workspace_id and not is_nil(b.verified_at) and is_nil(b.revoked_at),
      order_by: [desc: b.verified_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Revoke an active binding. Used both by a clean disconnect from the
  UI and by the system when a workspace pauses.
  """
  @spec revoke_binding(Ecto.UUID.t(), atom() | String.t()) ::
          {:ok, WalletBinding.t()} | {:error, atom()}
  def revoke_binding(binding_id, reason) when is_binary(binding_id) do
    reason_str = reason |> to_string() |> String.slice(0, 200)

    case Repo.get(WalletBinding, binding_id) do
      nil ->
        {:error, :not_found}

      %WalletBinding{revoked_at: %DateTime{}} ->
        {:error, :already_revoked}

      %WalletBinding{verified_at: nil} ->
        {:error, :not_verified}

      %WalletBinding{} = binding ->
        with {:ok, updated} <-
               binding
               |> WalletBinding.revoke_changeset(DateTime.utc_now(), reason_str)
               |> Repo.update(),
             {:ok, _ev} <- emit_audit(:revoked, updated, updated.user_id) do
          {:ok, updated}
        end
    end
  end

  @doc """
  Build the canonical EIP-191 message body for a challenge. Public so
  tests and the hook contract doc can stay in lockstep.
  """
  @spec build_message(%{
          workspace_id: Ecto.UUID.t(),
          address: String.t(),
          chain_id: integer(),
          nonce: String.t(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t()
        }) :: String.t()
  def build_message(%{
        workspace_id: workspace_id,
        address: address,
        chain_id: chain_id,
        nonce: nonce,
        issued_at: %DateTime{} = issued_at,
        expires_at: %DateTime{} = expires_at
      }) do
    """
    CryptoKorr wants to bind your wallet for an MVP delegation install.

    Workspace: #{workspace_id}
    Address:   #{address}
    Chain:     #{chain_id} (Base Sepolia)
    Nonce:     #{nonce}
    Issued:    #{DateTime.to_iso8601(issued_at)}
    Expires:   #{DateTime.to_iso8601(expires_at)}

    Signing this message proves you control the connected wallet. It
    does not authorize any transfer or delegation install.
    """
    |> String.trim_trailing("\n")
  end

  # --- internals ---------------------------------------------------------

  defp do_verify(%WalletBinding{} = binding, signature) do
    now = DateTime.utc_now()

    cond do
      DateTime.compare(now, binding.expires_at) == :gt ->
        emit_failure_audit(:expired, binding)
        {:error, :expired}

      true ->
        case Signature.verify_eip191(binding.challenge_message, signature, binding.address) do
          :ok ->
            with {:ok, updated} <-
                   binding
                   |> WalletBinding.verify_changeset(now)
                   |> Repo.update(),
                 {:ok, _ev} <- emit_audit(:verified, updated, updated.user_id) do
              {:ok, updated}
            end

          {:error, reason} ->
            emit_failure_audit(reason, binding)
            {:error, reason}
        end
    end
  end

  defp emit_audit(event, %WalletBinding{} = binding, actor_id) do
    Audit.append_event(%{
      actor: :user,
      actor_id: actor_id,
      event_type: "wallet_binding." <> Atom.to_string(event),
      subject_type: "wallet_binding",
      subject_id: binding.id,
      correlation_id: binding.id,
      after_ref: redacted_snapshot(binding),
      workspace_id: binding.workspace_id
    })
  end

  defp emit_failure_audit(reason, %WalletBinding{} = binding) do
    Audit.append_event(%{
      actor: :user,
      actor_id: binding.user_id,
      event_type: "wallet_binding.failed",
      subject_type: "wallet_binding",
      subject_id: binding.id,
      correlation_id: binding.id,
      after_ref: %{
        address: binding.address,
        chain_id: binding.chain_id,
        reason: to_string(reason)
      },
      workspace_id: binding.workspace_id
    })
  end

  defp emit_failure_audit(reason, %{challenge_id: challenge_id}) do
    Audit.append_event(%{
      actor: :user,
      event_type: "wallet_binding.failed",
      subject_type: "wallet_binding",
      subject_id: challenge_id,
      correlation_id: challenge_id,
      after_ref: %{reason: to_string(reason)}
    })
  end

  # `after_ref` carries only public metadata — never the nonce, never
  # the challenge message body, never the signature. The audit event is
  # public-by-default; the secrets stay on the row, which is read-only
  # to operators with the workspace.
  defp redacted_snapshot(%WalletBinding{} = binding) do
    %{
      address: binding.address,
      chain_id: binding.chain_id,
      expires_at: binding.expires_at,
      verified_at: binding.verified_at,
      revoked_at: binding.revoked_at
    }
  end

  defp generate_nonce do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end

  defp valid_address?("0x" <> hex) when byte_size(hex) == 40 do
    String.match?(hex, ~r/^[0-9a-fA-F]{40}$/)
  end

  defp valid_address?(_), do: false
end
