defmodule Bank.Policies.Versions do
  @moduledoc """
  Workspace-scoped versioned draft/publish/rollback context for
  policy bundles (#223).

  This module composes `Bank.Policies` (which versions individual
  rules through a `supersedes_id` chain) with a SET-level
  aggregate so an operator can:

    * open a draft cloned from the current published version,
    * edit the draft's rule set without affecting runtime,
    * publish the draft (atomically supersedes the prior
      published row), and
    * roll back to a prior published version (atomically
      supersedes the current row and re-publishes the target).

  ## Read-only side-effect contract

  This context emits audit events on publish / rollback and
  draft creation. It does NOT enqueue Oban jobs, broadcast on
  PubSub, call external delivery channels, or trigger chain
  dispatch. Runtime wiring (decisions consulting
  `PolicyVersion` instead of `Bank.Policies.load_active_ruleset/1`)
  lands in #226.

  ## Workspace boundary

  Every public function takes `workspace_id` (or a row already
  workspace-scoped via `get_in_workspace/2`). Cross-workspace
  reads collapse to `nil`; cross-workspace writes refuse.

  ## Public surface

      # reads
      current_published(workspace_id)
      list_versions(workspace_id, opts)
      get_in_workspace(id, workspace_id)

      # writes (all audited)
      create_draft(workspace_id, opts)
      update_draft_rule_ids(version, rule_ids, opts)
      publish_draft(version, opts)
      rollback_to_version(version, opts)

  ## Atomic invariants enforced by transaction + DB

    * At most ONE `:published` version per workspace at a time
      (partial unique index `workspace_id WHERE status = 'published'`).
    * Per-workspace `version_number` sequence is dense and
      increasing (`next_version_number/1` reads MAX + 1 inside the
      same transaction as the insert).
    * Publish transitions are all-or-nothing: the new draft flips
      to `:published` AND the prior published flips to
      `:superseded` AND an audit event is appended in one
      `Repo.transaction/1`.
    * Rollback is the same shape in reverse.

  ## Acceptance bullets (#223) → covered

    * **Admin can create a draft from the current published
      policy** — `create_draft/2` clones the current published's
      rule_ids list (or starts empty if none).
    * **Draft can be edited without affecting runtime** —
      `update_draft_rule_ids/3` only mutates `:draft` rows; the
      `:published` row's rule_ids is frozen by the schema's
      `update_draft_changeset/2` guard. Tests assert that
      `current_published/1` is unchanged across a draft edit.
    * **Publishing creates immutable snapshot used by future
      decisions** — `publish_draft/2` flips `:draft → :published`
      atomically, then attempts to mutate `rule_ids` are
      rejected at the schema layer.
    * **Old decisions replay with old policy references** —
      already preserved by the existing `DecisionEnvelope.policy_snapshot_ref`
      pinning; this context does not change that.
    * **Rollback to previous published version is possible** —
      `rollback_to_version/2` re-publishes a `:superseded` row.
  """

  import Ecto.Query

  alias Bank.Audit
  alias Bank.Policies.PolicyVersion
  alias Bank.Repo

  @typedoc """
  `create_draft/2` and `publish_draft/2` outcomes.
  """
  @type create_result ::
          {:ok, PolicyVersion.t()}
          | {:error, :no_published_to_clone}
          | {:error, Ecto.Changeset.t()}

  @type publish_result ::
          {:ok, PolicyVersion.t()}
          | {:error, :not_a_draft}
          | {:error, Ecto.Changeset.t()}

  @type rollback_result ::
          {:ok, PolicyVersion.t()}
          | {:error, :not_a_superseded_version}
          | {:error, :rollback_target_workspace_mismatch}
          | {:error, Ecto.Changeset.t()}

  # --- reads -------------------------------------------------------------

  @doc """
  Returns the current `:published` row for a workspace, or `nil`
  when no version has ever been published. Cross-workspace
  probes collapse to `nil`.
  """
  @spec current_published(binary()) :: PolicyVersion.t() | nil
  def current_published(workspace_id) when is_binary(workspace_id) do
    Repo.one(
      from(v in PolicyVersion,
        where: v.workspace_id == ^workspace_id and v.status == ^:published
      )
    )
  end

  def current_published(_), do: nil

  @doc """
  Resolve the workspace's currently-pinned policy snapshot for a
  decision (#226).

  When a `:published` PolicyVersion exists for the workspace,
  returns:

      %{
        rules:           [%PolicyRule{}, ...],   # active rules in version's rule_ids list
        rule_ids_in_version: [<uuid>, ...],      # the version's authoritative list
        version_id:      <uuid>,
        version_number:  <integer>
      }

  When no `:published` PolicyVersion exists, returns `nil` — the
  caller (typically `Bank.Decisions.evaluate_policy/3`) should
  fall back to legacy `Bank.Policies.load_active_ruleset/1`
  behavior. This preserves backward compatibility for workspaces
  that were created before the policy-version surface
  (greenfield + alpha workspaces).

  Rules in the version's `rule_ids` list that no longer resolve
  to an `:active` `PolicyRule` are silently dropped from the
  returned `:rules` list, but the original `:rule_ids_in_version`
  list is preserved verbatim so the decision envelope can pin
  the original list and a reviewer can spot drift later. The
  caller's fail-closed logic decides what to do when the
  resolved rule list is empty (e.g. produce a hold outcome).
  """
  @spec snapshot_for_workspace(binary()) :: map() | nil
  def snapshot_for_workspace(workspace_id) when is_binary(workspace_id) do
    case current_published(workspace_id) do
      nil ->
        nil

      %PolicyVersion{} = version ->
        ids = PolicyVersion.rule_ids_list(version)

        # #226 P2: scope rule resolution to the requested
        # workspace's `policy_rules.workspace_id`. Without this
        # filter, a malformed PolicyVersion in workspace A whose
        # `rule_ids` list cited a rule id from workspace B would
        # cause the runtime to evaluate B's rule in A's decision
        # path. Strict same-workspace match only — there is no
        # legacy "global rule" path to allow.
        rules =
          if ids == [] do
            []
          else
            Bank.Policies.PolicyRule
            |> Ecto.Query.where(
              [r],
              r.id in ^ids and r.state == ^:active and
                r.workspace_id == ^workspace_id
            )
            |> Bank.Repo.all()
          end

        %{
          rules: rules,
          rule_ids_in_version: ids,
          version_id: version.id,
          version_number: version.version_number
        }
    end
  end

  def snapshot_for_workspace(_), do: nil

  @doc """
  Lists policy versions for a workspace.

  Options:

    * `:status` — filter by `:draft | :published | :superseded`
      (or list). Defaults to all.
    * `:limit`  — page size cap. Default 100.

  Order: `version_number` desc (newest-first).
  """
  @spec list_versions(binary(), keyword()) :: [PolicyVersion.t()]
  def list_versions(workspace_id, opts \\ []) when is_binary(workspace_id) do
    PolicyVersion
    |> where([v], v.workspace_id == ^workspace_id)
    |> apply_status_filter(Keyword.get(opts, :status))
    |> order_by([v], desc: v.version_number)
    |> limit(^Keyword.get(opts, :limit, 100))
    |> Repo.all()
  end

  @doc """
  Look up a version by id, scoped to a workspace. Returns `nil`
  for a row in a sibling workspace — collapses to the same
  outcome as a missing row so the caller cannot distinguish a
  cross-workspace probe from a not-found.
  """
  @spec get_in_workspace(binary(), binary()) :: PolicyVersion.t() | nil
  def get_in_workspace(id, workspace_id) when is_binary(id) and is_binary(workspace_id) do
    Repo.one(
      from(v in PolicyVersion,
        where: v.id == ^id and v.workspace_id == ^workspace_id
      )
    )
  end

  # --- writes ------------------------------------------------------------

  @doc """
  Open a new draft policy version for a workspace.

  Behavior:

    * If a `:published` row exists for the workspace, the new
      draft clones its `rule_ids` list and sets `supersedes_id`
      to the current published id. The new draft is offered as
      the next iteration of that version.
    * If no `:published` row exists yet (greenfield workspace),
      the draft starts with `rule_ids: %{"items" => []}` and
      `supersedes_id: nil`.

  Caller-provided options:

    * `:created_by`  — required actor enum (`:user`, `:operator`,
      `:agent`, `:runtime`, `:system`).
    * `:actor_id`    — required UUID of the actor (audit).
    * `:rule_ids`    — optional explicit `%{"items" => [...]}`
      to seed the draft instead of cloning from current
      published. Useful for greenfield bootstrap.

  Audit: emits `policy.version.draft_created` on success.

  Returns `{:ok, draft}` on success or `{:error, changeset}`.
  """
  @spec create_draft(binary(), keyword()) :: create_result()
  def create_draft(workspace_id, opts) when is_binary(workspace_id) do
    created_by = Keyword.fetch!(opts, :created_by)
    actor_id = Keyword.fetch!(opts, :actor_id)
    explicit_rule_ids = Keyword.get(opts, :rule_ids)

    Repo.transaction(fn ->
      current = current_published_locked(workspace_id)

      seed_rule_ids =
        cond do
          explicit_rule_ids -> explicit_rule_ids
          current -> current.rule_ids
          true -> %{"items" => []}
        end

      version_number = next_version_number(workspace_id)

      attrs = %{
        workspace_id: workspace_id,
        version_number: version_number,
        rule_ids: seed_rule_ids,
        created_by: created_by,
        supersedes_id: current && current.id
      }

      case attrs |> PolicyVersion.create_changeset() |> Repo.insert() do
        {:ok, draft} ->
          {:ok, _audit} =
            Audit.append_event(
              Bank.Audit.Events.policy_version_draft_created(
                draft,
                actor_id: actor_id,
                actor: created_by
              )
            )

          draft

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Update a draft's rule_ids list. The version struct passed in
  MUST be in `:draft` state at the DB layer; the helper reloads
  with FOR UPDATE inside a transaction so a concurrent publish
  can't race the edit. Returns `{:error, :not_a_draft}` if the
  DB row is no longer a draft.

  No audit event is emitted for draft edits — drafts are
  iteration noise; only the eventual publish records the
  immutable snapshot.
  """
  @spec update_draft_rule_ids(PolicyVersion.t(), map(), keyword()) ::
          {:ok, PolicyVersion.t()}
          | {:error, :not_a_draft}
          | {:error, Ecto.Changeset.t()}
  def update_draft_rule_ids(
        %PolicyVersion{id: id, workspace_id: workspace_id},
        rule_ids,
        _opts \\ []
      ) do
    Repo.transaction(fn ->
      case lock_for_update(id, workspace_id) do
        nil ->
          Repo.rollback(:not_a_draft)

        %PolicyVersion{status: :draft} = locked ->
          locked
          |> PolicyVersion.update_draft_changeset(%{rule_ids: rule_ids})
          |> Repo.update()
          |> case do
            {:ok, updated} -> updated
            {:error, cs} -> Repo.rollback(cs)
          end

        _other ->
          Repo.rollback(:not_a_draft)
      end
    end)
  end

  @doc """
  Publish a draft. Atomically:

    1. Re-loads the draft FOR UPDATE inside a transaction; if it
       is no longer `:draft` (raced by another publisher), returns
       `{:error, :not_a_draft}`.
    2. If a `:published` row exists for the workspace, marks it
       `:superseded`.
    3. Flips the draft to `:published`, sets `published_at`,
       `published_by`, and `effective_at`.
    4. Appends a `policy.version.published` audit event.

  Required opts: `:published_by` (actor enum), `:actor_id` (UUID).
  Optional opts: `:effective_at`, `:now`.
  """
  @spec publish_draft(PolicyVersion.t(), keyword()) :: publish_result()
  def publish_draft(%PolicyVersion{id: id, workspace_id: workspace_id}, opts) do
    published_by = Keyword.fetch!(opts, :published_by)
    actor_id = Keyword.fetch!(opts, :actor_id)

    Repo.transaction(fn ->
      case lock_for_update(id, workspace_id) do
        nil ->
          Repo.rollback(:not_a_draft)

        %PolicyVersion{status: :draft} = draft ->
          prior = current_published_locked(workspace_id)

          if prior do
            case prior |> PolicyVersion.supersede_changeset() |> Repo.update() do
              {:ok, _} -> :ok
              {:error, cs} -> Repo.rollback(cs)
            end
          end

          # #224 P2: atomically promote any `:draft` rules in this
          # version's `rule_ids` list to `:active` BEFORE the
          # version flips to `:published`. The policy-builder UI
          # creates draft-added and draft-revised rules with
          # `state: :draft` (#224 P2-2 fix); this is the explicit
          # activation step that makes them live for runtime
          # decisions exactly when the version becomes published.
          activate_draft_rules!(draft)

          case draft |> PolicyVersion.publish_changeset(opts) |> Repo.update() do
            {:ok, published} ->
              {:ok, _audit} =
                Audit.append_event(
                  Bank.Audit.Events.policy_version_published(
                    published,
                    prior,
                    actor_id: actor_id,
                    actor: published_by
                  )
                )

              published

            {:error, cs} ->
              Repo.rollback(cs)
          end

        _other ->
          Repo.rollback(:not_a_draft)
      end
    end)
  end

  # Promote every `:draft` `PolicyRule` referenced by the given
  # version's `rule_ids` list to `:active`. Workspace-scoped per
  # the #226 P2 contract — never touches a sibling workspace's
  # rules even if the draft's `rule_ids` somehow cited one.
  defp activate_draft_rules!(%PolicyVersion{} = draft) do
    ids = PolicyVersion.rule_ids_list(draft)

    if ids != [] do
      now = DateTime.utc_now()

      from(r in Bank.Policies.PolicyRule,
        where:
          r.id in ^ids and r.state == ^:draft and
            r.workspace_id == ^draft.workspace_id
      )
      |> Repo.update_all(set: [state: :active, updated_at: now])
    end

    :ok
  end

  @doc """
  Roll back to a prior `:superseded` policy version. Atomically:

    1. Re-loads the rollback target FOR UPDATE; if it is not
       `:superseded`, returns `{:error, :not_a_superseded_version}`.
    2. Re-loads the workspace's current `:published` row FOR
       UPDATE; if the target's `workspace_id` differs from the
       current's, returns `{:error,
       :rollback_target_workspace_mismatch}` (defence-in-depth;
       `get_in_workspace/2` already prevents this at the API
       layer).
    3. Marks the current `:published` `:superseded`.
    4. Flips the target back to `:published`, with a fresh
       `effective_at` (the rollback time). `published_at` is
       NOT changed — it stays the original publication time.
    5. Appends a `policy.version.rolled_back` audit event.

  Required opts: `:actor`, `:actor_id`.
  """
  @spec rollback_to_version(PolicyVersion.t(), keyword()) :: rollback_result()
  def rollback_to_version(%PolicyVersion{id: id, workspace_id: workspace_id}, opts) do
    actor = Keyword.fetch!(opts, :actor)
    actor_id = Keyword.fetch!(opts, :actor_id)

    Repo.transaction(fn ->
      case lock_for_update(id, workspace_id) do
        nil ->
          Repo.rollback(:not_a_superseded_version)

        %PolicyVersion{status: :superseded, workspace_id: target_ws} = target ->
          if target_ws != workspace_id do
            Repo.rollback(:rollback_target_workspace_mismatch)
          else
            current = current_published_locked(workspace_id)

            if current do
              case current |> PolicyVersion.supersede_changeset() |> Repo.update() do
                {:ok, _} -> :ok
                {:error, cs} -> Repo.rollback(cs)
              end
            end

            case target |> PolicyVersion.rollback_changeset(opts) |> Repo.update() do
              {:ok, restored} ->
                {:ok, _audit} =
                  Audit.append_event(
                    Bank.Audit.Events.policy_version_rolled_back(
                      restored,
                      current,
                      actor_id: actor_id,
                      actor: actor
                    )
                  )

                restored

              {:error, cs} ->
                Repo.rollback(cs)
            end
          end

        _other ->
          Repo.rollback(:not_a_superseded_version)
      end
    end)
  end

  @doc """
  Discard an open draft. Deletes the draft row in a single
  transaction and appends a `policy.version.draft_discarded`
  audit event so the trail records what was thrown away.

  Drafts are never consulted by the decision pipeline, so a
  discarded draft cannot be referenced by a past decision —
  deletion (rather than soft archive) is safe for replay
  determinism.

  Returns `{:error, :not_a_draft}` when the row was already
  published / superseded by the time the transaction reloaded it.

  Required opts: `:actor` (enum), `:actor_id` (UUID).
  """
  @type discard_result ::
          {:ok, PolicyVersion.t()}
          | {:error, :not_a_draft}
          | {:error, Ecto.Changeset.t()}

  @spec discard_draft(PolicyVersion.t(), keyword()) :: discard_result()
  def discard_draft(%PolicyVersion{id: id, workspace_id: workspace_id}, opts) do
    actor = Keyword.fetch!(opts, :actor)
    actor_id = Keyword.fetch!(opts, :actor_id)

    Repo.transaction(fn ->
      case lock_for_update(id, workspace_id) do
        nil ->
          Repo.rollback(:not_a_draft)

        %PolicyVersion{status: :draft} = draft ->
          case Repo.delete(draft) do
            {:ok, deleted} ->
              {:ok, _audit} =
                Audit.append_event(
                  Bank.Audit.Events.policy_version_draft_discarded(
                    deleted,
                    actor_id: actor_id,
                    actor: actor
                  )
                )

              deleted

            {:error, cs} ->
              Repo.rollback(cs)
          end

        _other ->
          Repo.rollback(:not_a_draft)
      end
    end)
  end

  @doc """
  Classify a draft's rule set against the workspace's currently
  published version. Used by the Advanced policy screen to:

    * surface a per-rule "tightening vs expansion" badge so the
      operator knows whether publishing would loosen or tighten
      the agent's authority, and
    * surface a `requires_permission_reinstall?` banner so the
      operator cannot silently grant the agent broader on-chain
      authority than the currently-installed permission covers.

  Returns:

      %{
        tightening: [change],
        expansion:  [change],
        unchanged:  [policy_rule],
        requires_permission_reinstall?: boolean
      }

  Each `change` map carries:

      %{
        kind:      :added | :removed | :modified,
        rule_type: atom,
        rule_id:   uuid,       # draft side id, or published id for :removed
        prior:     %PolicyRule{} | nil,
        next:      %PolicyRule{} | nil,
        reason:    "humanise summary of why this counts as tightening/expansion"
      }

  ## Classification rules (conservative — see Phase 3 doc)

    * **Tightening** (no reinstall):
      - lower per-tx / rolling-cap limits
      - lower slippage ceiling
      - shorter rolling window with same cap
      - shrinking an allowlist (removing assets / chains / routers)
      - growing a denylist
      - autonomy_tier moving toward `:block`
      - adding any new rule (new constraints are tightening)

    * **Expansion** (reinstall required):
      - higher per-tx / rolling-cap limits
      - higher slippage ceiling
      - longer rolling window with same cap
      - growing an allowlist (new assets / chains / routers)
      - shrinking a denylist
      - autonomy_tier moving toward `:auto`
      - changing allowlist/denylist `mode` (flipping the rule's
        intent is always treated as expansion)
      - removing any rule (dropping a constraint is expansion)
      - any change the classifier can't prove is tightening
        (defensive default — unknown shapes never silently land
        as "safe")
  """
  @type diff_result :: %{
          required(:tightening) => [map()],
          required(:expansion) => [map()],
          required(:unchanged) => [Bank.Policies.PolicyRule.t()],
          required(:requires_permission_reinstall?) => boolean()
        }

  @spec diff_against_published(PolicyVersion.t()) :: diff_result()
  def diff_against_published(%PolicyVersion{workspace_id: ws_id} = draft) do
    published = current_published(ws_id)

    published_rules =
      case published do
        nil ->
          []

        %PolicyVersion{} = pv ->
          ids = PolicyVersion.rule_ids_list(pv)
          fetch_rules_in_workspace(ids, ws_id)
      end

    draft_rules =
      draft
      |> PolicyVersion.rule_ids_list()
      |> fetch_rules_in_workspace(ws_id, [:active, :draft])

    Bank.Policies.PolicyDiff.classify(published_rules, draft_rules)
  end

  @doc """
  Diff two arbitrary published/superseded policy versions
  belonging to the same workspace. Used by the agent-screen
  permission-outdated detector to answer "did any expansion
  publish land since the agent's permission was granted?".

  Both versions must belong to the same workspace. Returns
  the same shape as `diff_against_published/1`.
  """
  @spec diff_versions(PolicyVersion.t() | nil, PolicyVersion.t()) :: diff_result()
  def diff_versions(prior, %PolicyVersion{workspace_id: ws_id} = next) do
    prior_rules =
      case prior do
        nil ->
          []

        %PolicyVersion{workspace_id: ^ws_id} = pv ->
          pv |> PolicyVersion.rule_ids_list() |> fetch_rules_in_workspace(ws_id)

        %PolicyVersion{} ->
          # Defensive guard: never silently diff across workspaces.
          []
      end

    next_rules =
      next |> PolicyVersion.rule_ids_list() |> fetch_rules_in_workspace(ws_id)

    Bank.Policies.PolicyDiff.classify(prior_rules, next_rules)
  end

  @doc """
  Have any "expansion" publishes happened in this workspace since
  the given `granted_at` timestamp?

  Walks every `:published` / `:superseded` `PolicyVersion` whose
  `effective_at` is strictly after `granted_at`, in chronological
  order. For each such version, compares it against the
  immediately-prior version (via the `supersedes_id` chain) and
  returns `true` on the first expansion classification.

  Returns `false` when `granted_at` is `nil` (legacy
  un-policy-tracked installs are not flagged as outdated; if a
  workspace has never published a policy version, the runtime
  uses the legacy active-ruleset path and there is nothing to be
  "outdated" against).
  """
  @spec expansion_published_since?(binary(), DateTime.t() | nil) :: boolean()
  def expansion_published_since?(_workspace_id, nil), do: false

  def expansion_published_since?(workspace_id, %DateTime{} = granted_at)
      when is_binary(workspace_id) do
    versions =
      Repo.all(
        from v in PolicyVersion,
          where:
            v.workspace_id == ^workspace_id and v.status in ^[:published, :superseded] and
              v.effective_at > ^granted_at,
          order_by: [asc: v.effective_at, asc: v.version_number]
      )

    Enum.any?(versions, fn v ->
      prior = if v.supersedes_id, do: Repo.get(PolicyVersion, v.supersedes_id), else: nil
      diff = diff_versions(prior, v)
      diff.requires_permission_reinstall?
    end)
  end

  def expansion_published_since?(_workspace_id, _other), do: false

  # ---------------------------------------------------------------
  # Rule fetch helpers used by the diff entry points.
  # ---------------------------------------------------------------

  defp fetch_rules_in_workspace(ids, ws_id, states \\ [:active])

  defp fetch_rules_in_workspace([], _ws_id, _states), do: []

  defp fetch_rules_in_workspace(ids, ws_id, states) when is_list(ids) do
    Bank.Policies.PolicyRule
    |> where(
      [r],
      r.id in ^ids and r.state in ^states and r.workspace_id == ^ws_id
    )
    |> Repo.all()
  end

  # --- internal ----------------------------------------------------------

  defp current_published_locked(workspace_id) do
    Repo.one(
      from(v in PolicyVersion,
        where: v.workspace_id == ^workspace_id and v.status == ^:published,
        lock: "FOR UPDATE"
      )
    )
  end

  defp lock_for_update(id, workspace_id) do
    Repo.one(
      from(v in PolicyVersion,
        where: v.id == ^id and v.workspace_id == ^workspace_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp next_version_number(workspace_id) do
    max =
      Repo.one(
        from(v in PolicyVersion,
          where: v.workspace_id == ^workspace_id,
          select: max(v.version_number)
        )
      )

    (max || 0) + 1
  end

  defp apply_status_filter(query, nil), do: query

  defp apply_status_filter(query, statuses) when is_list(statuses) do
    from(v in query, where: v.status in ^statuses)
  end

  defp apply_status_filter(query, status) when is_atom(status) do
    from(v in query, where: v.status == ^status)
  end
end
