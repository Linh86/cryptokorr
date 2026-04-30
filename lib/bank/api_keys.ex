defmodule Bank.APIKeys do
  @moduledoc """
  API key bounded context (#218a).

  Owns the `api_keys` table and its lifecycle: creation, soft-
  revocation, and listing. The authentication path that actually
  validates a presented key against `secret_hash` is intentionally
  NOT in this module — that lands in `BankWeb.Plugs.VerifyAPIKey`
  in #218b.

  ## Secret hygiene contract

  The raw secret is shown EXACTLY ONCE: as the third element of
  the `{:ok, api_key, raw_secret}` tuple returned by
  `create_key/4`. After that point:

    * No column on `api_keys` stores the raw secret. `secret_hash`
      stores the SHA-256 of the secret bytes; `prefix` stores the
      first 8 base32 chars (which act as a public lookup token,
      not as a credential).
    * `Bank.Audit.Events.api_key_created/2` does NOT include the
      raw secret in `after_ref` — it ships only id, prefix, role,
      name, and expires_at.
    * The `%APIKey{}` struct itself never carries the raw secret.
      `inspect/1` and any future `Logger.info(api_key)` cannot
      leak it.

  Callers that ignore the returned secret immediately lose access
  to it forever — that is the entire point.

  ## Wire format

  The on-the-wire key is `cb_<prefix>_<rest>` where:

    * `cb_` is the static namespace (collision-avoiding prefix in
      logs and grep).
    * `<prefix>` is 8 lowercased base32 chars (the column).
    * `<rest>` is the remaining base32-encoded entropy.

  Together `<prefix>_<rest>` is a base32 encoding of 32 bytes of
  `crypto.strong_rand_bytes/1` output (~256 bits of entropy). The
  prefix split is purely for fast indexed lookup at auth time;
  the credential strength comes from the full secret.
  """

  import Ecto.Query

  alias Bank.APIKeys.APIKey
  alias Bank.Audit
  alias Bank.Repo
  alias Bank.Workspaces.Workspace

  @secret_bytes 32
  @prefix_chars 8
  @namespace "cb_"

  @type create_opts :: [expires_at: DateTime.t() | nil]

  @doc """
  Mint a new API key. Returns `{:ok, api_key, raw_secret}` on
  success — `raw_secret` is the on-the-wire credential and is
  shown ONCE here. Persistence stores only the SHA-256 hash.

  An audit event of type `api_key.created` is appended in the
  same transaction so the audit row and the API key row never
  diverge.

  Required fields:
    * `workspace` — the workspace the key acts under.
    * `creator` — the `Bank.Accounts.User` issuing the key (audit
      actor + `created_by_user_id` FK).
    * `role` — one of `[:viewer, :operator, :admin, :owner]`.
      Bound to the key for the rest of its lifetime; rotation /
      role-flip is a separate `revoke + create` cycle in this PR.
    * `name` — a human label so operators can recognise the key
      in a list. Free-form, length-validated by the changeset.

  Options:
    * `:expires_at` — optional `DateTime` ttl.

  ## Creator privilege — deferred to the management surface

  This context primitive trusts its caller. It does NOT verify
  that `creator`'s membership role is `>= role` — i.e. an
  operator could in principle mint an `:admin` key by calling
  this function directly from IEx or a custom worker. The check
  belongs at the management entry point (a future
  `BankWeb.API.V1.APIKeyController` or operator console form),
  where the controller plug can read `current_scope.role` and
  refuse a request that would mint a stronger key than the caller
  holds. There is no management endpoint in #218a, so the
  enforcement layer simply does not exist yet; the only callers
  today are the test suite and IEx, both of which are inside the
  trust boundary. The future PR that adds the management surface
  MUST enforce `Membership.role_at_least?(creator_role, role)` —
  this docstring is the contract handoff.
  """
  @spec create_key(
          Workspace.t(),
          Bank.Accounts.User.t(),
          APIKey.role(),
          String.t(),
          create_opts()
        ) ::
          {:ok, APIKey.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_key(%Workspace{} = workspace, creator, role, name, opts \\ [])
      when role in [:viewer, :operator, :admin, :owner] and is_binary(name) do
    raw_secret = generate_secret()
    {prefix, _rest} = split_for_storage(raw_secret)

    attrs = %{
      workspace_id: workspace.id,
      created_by_user_id: creator.id,
      role: role,
      name: name,
      prefix: prefix,
      secret_hash: hash_secret(raw_secret),
      expires_at: Keyword.get(opts, :expires_at)
    }

    Repo.transaction(fn ->
      with {:ok, api_key} <-
             %APIKey{} |> APIKey.create_changeset(attrs) |> Repo.insert(),
           {:ok, _event} <-
             Audit.append_event(Bank.Audit.Events.api_key_created(api_key, creator)) do
        {api_key, raw_secret}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {api_key, raw_secret}} -> {:ok, api_key, raw_secret}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Soft-revoke a key. Idempotent — calling on an already-revoked
  key is a no-op (returns `{:ok, api_key}` without re-emitting
  the audit event or moving `revoked_at`).

  An audit event of type `api_key.revoked` is appended on the
  first transition. The `actor` opt names the user requesting
  the revoke; defaults to the key's original creator if absent.
  """
  @spec revoke_key(APIKey.t(), keyword()) :: {:ok, APIKey.t()} | {:error, term()}
  def revoke_key(api_key, opts \\ [])

  def revoke_key(%APIKey{revoked_at: %DateTime{}} = api_key, _opts), do: {:ok, api_key}

  def revoke_key(%APIKey{} = api_key, opts) do
    actor = Keyword.get(opts, :actor)

    Repo.transaction(fn ->
      with {:ok, revoked} <- api_key |> APIKey.revoke_changeset() |> Repo.update(),
           {:ok, _event} <-
             Audit.append_event(Bank.Audit.Events.api_key_revoked(revoked, actor: actor)) do
        revoked
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Fetch an API key by id. Returns `{:ok, key}` or `{:error, :not_found}`.
  """
  @spec get_key(String.t()) :: {:ok, APIKey.t()} | {:error, :not_found}
  def get_key(id) when is_binary(id) do
    case Repo.get(APIKey, id) do
      nil -> {:error, :not_found}
      %APIKey{} = key -> {:ok, key}
    end
  end

  @doc """
  Verify a presented raw API key (#218b).

  Pipeline:

    1. Match the wire format `cb_<body>`. Anything else →
       `:malformed`. Defends against blind probes that send a
       random uppercase-base32 or non-base32 string.
    2. Pull the first 8 chars of the body and look up by `prefix`.
       Missing → `:not_found`.
    3. Constant-time compare `:crypto.hash(:sha256, body)` against
       the row's `secret_hash` via `Plug.Crypto.secure_compare/2`.
       Mismatch → `:hash_mismatch`. The compare runs even when the
       hashes are obviously different lengths so the timing remains
       independent of the row's contents.
    4. Lifecycle gates: `:revoked` if `revoked_at` is set;
       `:expired` if `expires_at` is in the past.

  Returns `{:ok, %APIKey{}, %Workspace{}}` on success — workspace
  is preloaded so the auth plug can populate
  `conn.assigns.current_scope.workspace` without a second query.

  Callers (the auth plug) MUST map every error variant to the same
  generic `401` response on the wire — distinguishing `:not_found`
  from `:hash_mismatch` to the client would let an attacker probe
  for valid prefixes. The distinct reasons exist purely for server-
  side logging and tests.
  """
  @spec verify_key(String.t()) ::
          {:ok, APIKey.t(), Bank.Workspaces.Workspace.t()}
          | {:error, :malformed | :not_found | :hash_mismatch | :revoked | :expired}
  def verify_key(@namespace <> body) when byte_size(body) > @prefix_chars do
    prefix = String.slice(body, 0, @prefix_chars)

    case Repo.one(from k in APIKey, where: k.prefix == ^prefix, preload: [:workspace]) do
      nil ->
        {:error, :not_found}

      %APIKey{} = key ->
        presented_hash = :crypto.hash(:sha256, body)

        cond do
          not Plug.Crypto.secure_compare(presented_hash, key.secret_hash) ->
            {:error, :hash_mismatch}

          APIKey.revoked?(key) ->
            {:error, :revoked}

          APIKey.expired?(key, DateTime.utc_now()) ->
            {:error, :expired}

          true ->
            {:ok, key, key.workspace}
        end
    end
  end

  def verify_key(_), do: {:error, :malformed}

  @doc """
  List all non-revoked keys for a workspace, newest first. Used
  by the (future) management UI; safe to call now.
  """
  @spec list_active_keys(String.t()) :: [APIKey.t()]
  def list_active_keys(workspace_id) when is_binary(workspace_id) do
    from(k in APIKey,
      where: k.workspace_id == ^workspace_id and is_nil(k.revoked_at),
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  List ALL keys for a workspace (including revoked), newest first.
  """
  @spec list_keys(String.t()) :: [APIKey.t()]
  def list_keys(workspace_id) when is_binary(workspace_id) do
    from(k in APIKey,
      where: k.workspace_id == ^workspace_id,
      order_by: [desc: k.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  List ALL keys for a workspace with the `created_by` user
  preloaded, newest first. Used by the management surface
  (#218c) so the listing can render the creator's email without
  N+1 lookups.
  """
  @spec list_keys_with_creator(String.t()) :: [APIKey.t()]
  def list_keys_with_creator(workspace_id) when is_binary(workspace_id) do
    from(k in APIKey,
      where: k.workspace_id == ^workspace_id,
      order_by: [desc: k.inserted_at],
      preload: [:created_by]
    )
    |> Repo.all()
  end

  @doc """
  Fetch a key by id scoped to a workspace (#218c). Returns
  `:not_found` for unknown ids AND for ids that belong to a
  different workspace — the management surface MUST NEVER let an
  admin from workspace A read or revoke a key in workspace B.
  """
  @spec get_workspace_key(String.t(), String.t()) ::
          {:ok, APIKey.t()} | {:error, :not_found}
  def get_workspace_key(workspace_id, id)
      when is_binary(workspace_id) and is_binary(id) do
    case Repo.one(
           from k in APIKey,
             where: k.id == ^id and k.workspace_id == ^workspace_id
         ) do
      nil -> {:error, :not_found}
      %APIKey{} = key -> {:ok, key}
    end
  end

  # `last_used_at` throttle window — see `touch_last_used/2`. The
  # value is intentionally large enough that an active key only
  # rolls its `last_used_at` once per window. Tests pass an
  # explicit threshold via the second arg.
  @touch_throttle_seconds 60 * 60

  @doc """
  Best-effort update of an API key's `last_used_at` (#218d).

  Throttles by inspecting the current `last_used_at`: if it was
  set within the last `threshold_seconds`, the call is a no-op
  and the existing struct is returned. Otherwise the column is
  updated to `DateTime.utc_now/0` via `update_all` so concurrent
  requests do not generate Ecto.StaleEntryError.

  Callers (`BankWeb.Plugs.VerifyAPIKey`) MUST treat the return
  value as best-effort — a transient DB write failure here
  cannot be allowed to fail an authenticated request. The plug
  invokes this AFTER the verify+role checks have already
  succeeded; revoked / expired keys never reach this path.

  Returns `{:ok, api_key}` either way (with the original
  `last_used_at` when throttled, or the updated value otherwise),
  or `{:error, reason}` if the underlying update failed — the
  plug logs the error and continues.
  """
  @spec touch_last_used(APIKey.t(), pos_integer()) :: {:ok, APIKey.t()} | {:error, term()}
  def touch_last_used(api_key, threshold_seconds \\ @touch_throttle_seconds)

  def touch_last_used(%APIKey{last_used_at: %DateTime{} = last} = api_key, threshold_seconds)
      when is_integer(threshold_seconds) do
    if DateTime.diff(DateTime.utc_now(), last, :second) < threshold_seconds do
      {:ok, api_key}
    else
      do_touch(api_key)
    end
  end

  def touch_last_used(%APIKey{last_used_at: nil} = api_key, _threshold_seconds) do
    # First use ever — always advance.
    do_touch(api_key)
  end

  defp do_touch(%APIKey{id: id} = api_key) do
    now = DateTime.utc_now()

    case Repo.update_all(
           from(k in APIKey, where: k.id == ^id),
           set: [last_used_at: now, updated_at: now]
         ) do
      {1, _} -> {:ok, %APIKey{api_key | last_used_at: now, updated_at: now}}
      {0, _} -> {:error, :not_found}
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  List API keys whose `last_used_at` falls inside `[from, to)`
  (#218d). Used by the daily aggregate worker to emit one
  `api_key.used` audit event per key per window.
  """
  @spec list_keys_used_between(DateTime.t(), DateTime.t()) :: [APIKey.t()]
  def list_keys_used_between(%DateTime{} = from, %DateTime{} = to) do
    from(k in APIKey,
      where: not is_nil(k.last_used_at) and k.last_used_at >= ^from and k.last_used_at < ^to,
      order_by: [asc: k.workspace_id, asc: k.id]
    )
    |> Repo.all()
  end

  @doc """
  True iff there's already an `api_key.used` audit row whose
  `after_ref.window_start` matches `window_start_iso` for this
  api_key id. Used by the worker to skip already-emitted keys
  on a re-run within the same window (idempotency guard).
  """
  @spec used_event_exists?(String.t(), String.t()) :: boolean()
  def used_event_exists?(api_key_id, window_start_iso)
      when is_binary(api_key_id) and is_binary(window_start_iso) do
    Repo.exists?(
      from e in Bank.Audit.AuditEvent,
        where:
          e.event_type == "api_key.used" and
            e.subject_type == "api_key" and
            e.subject_id == ^api_key_id and
            fragment("?->>'window_start' = ?", e.after_ref, ^window_start_iso)
    )
  end

  # --- Private helpers -----------------------------------------------------

  # 32 random bytes → ~256 bits of entropy. Encoded with base32
  # (lowercase, no padding) so the resulting string is URL-safe and
  # readable in operator copy/paste flows.
  defp generate_secret do
    raw = :crypto.strong_rand_bytes(@secret_bytes)
    encoded = Base.encode32(raw, case: :lower, padding: false)
    @namespace <> encoded
  end

  # The wire-shape secret is `cb_<encoded>`. We split off the first
  # 8 base32 chars (after the namespace) for the indexed `prefix`
  # column. The full encoded body is what `secret_hash` is computed
  # over (minus the namespace prefix, which is constant).
  defp split_for_storage(@namespace <> encoded) do
    {String.slice(encoded, 0, @prefix_chars), encoded}
  end

  defp hash_secret(@namespace <> encoded) do
    :crypto.hash(:sha256, encoded)
  end
end
