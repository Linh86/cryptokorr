defmodule Bank.Intents do
  @moduledoc """
  Intents bounded context.

  Owns the `AgentIntent` lifecycle: `submitted → evaluating → decided →
  (executing → executed) | blocked | cancelled | expired`. Accepts agent
  submissions, applies idempotency-key dedupe, and coordinates the
  evaluation pipeline by enqueueing work on the `intents.evaluate` queue
  (see `Bank.Runtime`).

  Public surface scope in v0.1:

    * accept an intent (create + persist + enqueue evaluation)
    * look up an intent and its linked decision / simulation / plan
    * operator cancellation (pre-execution)
    * replay bundle assembly (delegates to `Bank.Audit`)

  Evaluation, simulation, and decisioning belong to `Bank.Policies`,
  `Bank.Decisions`, and `Bank.Runtime` — not here.
  """

  import Ecto.Query

  alias Bank.Audit
  alias Bank.Audit.Events, as: AuditEvents
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime
  alias Ecto.Multi

  @default_limit 50
  @max_limit 200

  @supported_chains ~w(base)
  @supported_assets ~w(USDC)

  @doc """
  List intents for the control-tower intents page.

  Opts:

    * `:state` — single `AgentIntent` state atom (or `:all`, default)
    * `:kind`  — single `AgentIntent` kind atom (or `:all`, default)
    * `:limit` — positive integer, capped at `#{@max_limit}`, default
      `#{@default_limit}`
    * `:search` — case-insensitive substring match on agent_id or
      intent id

  Returns intents newest-first with their target counterparty and
  address-label preloaded for rendering.
  """
  @spec list(keyword()) :: [AgentIntent.t()]
  def list(opts \\ []) do
    state = Keyword.get(opts, :state, :all)
    kind = Keyword.get(opts, :kind, :all)
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    search = opts |> Keyword.get(:search) |> normalise_search()

    query =
      from(i in AgentIntent,
        order_by: [desc: i.submitted_at, desc: i.inserted_at],
        limit: ^limit,
        preload: [:target_counterparty, :target_address_label]
      )

    query
    |> apply_state_filter(state)
    |> apply_kind_filter(kind)
    |> apply_search_filter(search)
    |> Repo.all()
  end

  @doc """
  Count intents grouped by state, optionally scoped by the same
  non-state filters the intents page exposes.

  The breakdown itself slices by state, so the `:state` filter is
  intentionally ignored — applying it would leave every chip at zero
  except the one currently selected, which is useless. `:kind` and
  `:search` ARE applied, so an operator viewing `kind=transfer` sees
  the state distribution *within* their current scope rather than the
  global distribution across all kinds.

  Opts:

    * `:kind`   — single `AgentIntent` kind atom (or `:all`, default)
    * `:search` — case-insensitive substring match on agent_id or
      intent id

  Returns a map keyed by state atom with integer counts; all known
  states are present (missing states map to 0).
  """
  @spec counts_by_state(keyword()) :: %{atom() => non_neg_integer()}
  def counts_by_state(opts \\ []) do
    kind = Keyword.get(opts, :kind, :all)
    search = opts |> Keyword.get(:search) |> normalise_search()

    base = %{
      submitted: 0,
      evaluating: 0,
      decided: 0,
      executing: 0,
      executed: 0,
      blocked: 0,
      cancelled: 0,
      expired: 0
    }

    from(i in AgentIntent, group_by: i.state, select: {i.state, count(i.id)})
    |> apply_kind_filter(kind)
    |> apply_search_filter(search)
    |> Repo.all()
    |> Enum.reduce(base, fn {state, n}, acc -> Map.put(acc, state, n) end)
  end

  @doc """
  Look up a single intent by id with decision / plan preloaded. Returns
  `nil` if no such intent exists (callers that need a 404 lift this to
  `{:error, :not_found}` themselves).
  """
  @spec get(String.t()) :: AgentIntent.t() | nil
  def get(id) when is_binary(id) do
    Repo.get(AgentIntent, id)
    |> Repo.preload([:target_counterparty, :target_address_label])
  end

  @doc """
  Accept a freshly-submitted agent intent.

  `attrs` is the parsed `POST /v1/intents` body (string-keyed map). The
  facade normalises the body, computes a deterministic payload hash,
  enforces `(agent_id, idempotency_key)` idempotency, persists the
  `%AgentIntent{}` in `:submitted`, writes the `intent.submitted`
  audit event, and enqueues `EvaluateIntent` — all in a single
  `Ecto.Multi` so the four pieces stay consistent.

  Return shapes:

    * `{:ok, %{intent: intent, replay?: false}}` — first time we have
      seen this `(agent_id, idempotency_key)`.
    * `{:ok, %{intent: intent, replay?: true}}` — same `(agent_id,
      idempotency_key)` and a payload that hashes to the same value.
      No new row, no new audit event, no new job.
    * `{:error, {:idempotency_conflict, prior}}` — same key, different
      payload.
    * `{:error, {:unsupported_chain, chain}}` — `chain` was not `"base"`.
    * `{:error, {:unsupported_asset, asset}}` — `asset` was not `"USDC"`.
    * `{:error, {:invalid, reason}}` — caller supplied an unparseable
      shape (missing fields, bad amount, malformed UUID target,
      multiple/zero target keys); `reason` is a short atom or
      `%Ecto.Changeset{}`.

  This module is the only sanctioned write path for new intents.
  Callers must not insert `%AgentIntent{}` directly — doing so bypasses
  audit fan-out and the evaluation enqueue.
  """
  @spec submit(map(), keyword()) ::
          {:ok, %{intent: AgentIntent.t(), replay?: boolean()}}
          | {:error,
             {:idempotency_conflict, AgentIntent.t()}
             | {:unsupported_chain, String.t()}
             | {:unsupported_asset, String.t()}
             | {:invalid, term()}}
  def submit(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, normalized} <- normalize(attrs) do
      case lookup_existing(normalized.agent_id, normalized.idempotency_key) do
        nil ->
          do_insert(normalized, opts)

        %AgentIntent{payload_hash: hash} = existing
        when hash == normalized.payload_hash ->
          {:ok, %{intent: preload_target(existing), replay?: true}}

        %AgentIntent{} = existing ->
          {:error, {:idempotency_conflict, existing}}
      end
    end
  end

  defp do_insert(normalized, opts) do
    multi =
      Multi.new()
      |> Multi.insert(:intent, AgentIntent.changeset(%AgentIntent{}, normalized))
      |> Multi.run(:audit, fn _repo, %{intent: intent} ->
        intent
        |> AuditEvents.intent_submitted(audit_opts(opts))
        |> Audit.append_event()
      end)

    case Repo.transaction(multi) do
      {:ok, %{intent: intent}} ->
        case Runtime.enqueue_evaluation(intent.id) do
          {:ok, _job} ->
            {:ok, %{intent: preload_target(intent), replay?: false}}

          {:error, reason} ->
            {:error, {:invalid, {:enqueue_failed, reason}}}
        end

      {:error, :intent, %Ecto.Changeset{} = changeset, _} ->
        if idempotency_conflict?(changeset) do
          # The existence check above didn't see a row, but the unique
          # constraint did — concurrent submit raced us. Re-read so the
          # caller still gets the spec-shaped envelope.
          case lookup_existing(normalized.agent_id, normalized.idempotency_key) do
            %AgentIntent{payload_hash: hash} = existing
            when hash == normalized.payload_hash ->
              {:ok, %{intent: preload_target(existing), replay?: true}}

            %AgentIntent{} = existing ->
              {:error, {:idempotency_conflict, existing}}

            nil ->
              {:error, {:invalid, changeset}}
          end
        else
          {:error, {:invalid, changeset}}
        end

      {:error, :audit, reason, _} ->
        {:error, {:invalid, {:audit_failed, reason}}}
    end
  end

  defp idempotency_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:agent_id, {_msg, opts}} -> opts[:constraint] == :unique
      {:idempotency_key, {_msg, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp lookup_existing(agent_id, idempotency_key) do
    Repo.get_by(AgentIntent, agent_id: agent_id, idempotency_key: idempotency_key)
  end

  defp preload_target(%AgentIntent{} = intent) do
    Repo.preload(intent, [:target_counterparty, :target_address_label])
  end

  defp audit_opts(opts) do
    case Keyword.get(opts, :actor) do
      nil -> []
      actor -> [actor: actor]
    end
  end

  # --- normalisation ----------------------------------------------------

  @doc """
  Normalise a `POST /v1/intents` body into the attribute shape the
  `AgentIntent` changeset expects, validate the boundary invariants
  the runtime enforces today (`chain == "base"`, `asset == "USDC"`),
  and compute the deterministic `payload_hash`.

  Exposed for tests; the controller uses `submit/2`.
  """
  @spec normalize(map()) ::
          {:ok, map()}
          | {:error,
             {:unsupported_chain, String.t()}
             | {:unsupported_asset, String.t()}
             | {:invalid, atom()}}
  def normalize(attrs) when is_map(attrs) do
    with {:ok, agent_id} <- require_string(attrs, "agent_id"),
         {:ok, source} <- require_atom(attrs, "source", [:agent, :user, :runtime]),
         {:ok, idempotency_key} <- require_string(attrs, "idempotency_key"),
         {:ok, kind} <-
           require_atom(attrs, "kind", [:transfer, :swap, :scheduled_transfer]),
         {:ok, chain} <- require_chain(attrs),
         {:ok, asset} <- require_asset(attrs),
         {:ok, amount} <- require_amount(attrs),
         {:ok, target} <- normalise_target(Map.get(attrs, "target")) do
      base = %{
        agent_id: agent_id,
        source: source,
        idempotency_key: idempotency_key,
        kind: kind,
        asset: asset,
        chain: chain,
        amount: amount,
        notes: optional_string(attrs, "notes"),
        submitted_at: DateTime.utc_now()
      }

      attrs_for_changeset =
        base
        |> Map.merge(target)
        |> Map.put(:payload_hash, payload_hash(base, target))

      {:ok, attrs_for_changeset}
    end
  end

  # Deterministic SHA-256 of the canonical body fields. Excludes
  # `submitted_at` and any header-derived value so retries hash
  # identically when the request body matches.
  defp payload_hash(base, target) do
    canonical = %{
      "agent_id" => base.agent_id,
      "source" => Atom.to_string(base.source),
      "idempotency_key" => base.idempotency_key,
      "kind" => Atom.to_string(base.kind),
      "asset" => base.asset,
      "chain" => base.chain,
      "amount" => Decimal.to_string(base.amount, :normal),
      "notes" => base.notes,
      "target" => target_for_hash(target)
    }

    :sha256
    |> :crypto.hash(Jason.encode!(canonical))
    |> Base.encode16(case: :lower)
  end

  defp target_for_hash(%{target_counterparty_id: cp_id} = t) when is_binary(cp_id) do
    %{
      "counterparty_id" => cp_id,
      "address_label_id" => Map.get(t, :target_address_label_id),
      "raw_address" => nil
    }
  end

  defp target_for_hash(%{target_raw_address: raw}) when is_binary(raw) do
    %{"counterparty_id" => nil, "address_label_id" => nil, "raw_address" => raw}
  end

  defp normalise_target(target) when is_map(target) do
    cp_id = string_or_nil(Map.get(target, "counterparty_id"))
    label_id = string_or_nil(Map.get(target, "address_label_id"))
    raw_address = string_or_nil(Map.get(target, "raw_address"))

    cond do
      cp_id && raw_address ->
        {:error, {:invalid, :target_ambiguous}}

      is_nil(cp_id) && is_nil(raw_address) ->
        {:error, {:invalid, :target_missing}}

      label_id && is_nil(cp_id) ->
        {:error, {:invalid, :target_label_without_counterparty}}

      cp_id && not valid_uuid?(cp_id) ->
        {:error, {:invalid, :target_counterparty_id}}

      label_id && not valid_uuid?(label_id) ->
        {:error, {:invalid, :target_address_label_id}}

      cp_id ->
        target = %{target_counterparty_id: cp_id}

        target =
          if label_id, do: Map.put(target, :target_address_label_id, label_id), else: target

        {:ok, target}

      true ->
        {:ok, %{target_raw_address: raw_address}}
    end
  end

  defp normalise_target(_), do: {:error, {:invalid, :target_missing}}

  defp valid_uuid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  defp optional_string(attrs, key) do
    case Map.get(attrs, key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp require_string(attrs, key) do
    case Map.get(attrs, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp require_atom(attrs, key, allowed) do
    case Map.get(attrs, key) do
      v when is_binary(v) ->
        atom = atom_from_allowed(v, allowed)

        if atom do
          {:ok, atom}
        else
          {:error, {:invalid, String.to_atom(key)}}
        end

      _ ->
        {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp atom_from_allowed(value, allowed) do
    Enum.find(allowed, fn atom -> Atom.to_string(atom) == value end)
  end

  defp require_chain(attrs) do
    case Map.get(attrs, "chain") do
      v when is_binary(v) and v != "" ->
        if v in @supported_chains, do: {:ok, v}, else: {:error, {:unsupported_chain, v}}

      _ ->
        {:error, {:invalid, :chain}}
    end
  end

  defp require_asset(attrs) do
    case Map.get(attrs, "asset") do
      v when is_binary(v) and v != "" ->
        if v in @supported_assets, do: {:ok, v}, else: {:error, {:unsupported_asset, v}}

      _ ->
        {:error, {:invalid, :asset}}
    end
  end

  defp require_amount(attrs) do
    case Map.get(attrs, "amount") do
      v when is_binary(v) and v != "" ->
        case Decimal.parse(v) do
          {decimal, ""} -> validate_positive(decimal)
          _ -> {:error, {:invalid, :amount}}
        end

      %Decimal{} = d ->
        validate_positive(d)

      _ ->
        {:error, {:invalid, :amount}}
    end
  end

  defp validate_positive(%Decimal{} = d) do
    if Decimal.compare(d, Decimal.new(0)) == :gt do
      {:ok, d}
    else
      {:error, {:invalid, :amount}}
    end
  end

  # --- private -----------------------------------------------------------

  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp_limit(_), do: @default_limit

  defp normalise_search(nil), do: nil
  defp normalise_search(""), do: nil

  defp normalise_search(term) when is_binary(term) do
    term
    |> String.trim()
    |> case do
      "" -> nil
      t -> t
    end
  end

  defp apply_state_filter(q, :all), do: q
  defp apply_state_filter(q, nil), do: q
  defp apply_state_filter(q, state) when is_atom(state), do: where(q, [i], i.state == ^state)

  defp apply_kind_filter(q, :all), do: q
  defp apply_kind_filter(q, nil), do: q
  defp apply_kind_filter(q, kind) when is_atom(kind), do: where(q, [i], i.kind == ^kind)

  defp apply_search_filter(q, nil), do: q

  defp apply_search_filter(q, term) do
    pattern = "%" <> term <> "%"

    # id is a UUID field; cast explicitly so ILIKE matches on its textual
    # form. agent_id is already a string.
    where(
      q,
      [i],
      fragment("CAST(? AS text) ILIKE ?", i.id, ^pattern) or
        ilike(i.agent_id, ^pattern)
    )
  end
end
