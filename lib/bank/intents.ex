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

  This module is the facade. Schemas, changesets, and query logic arrive
  with issue #4. Evaluation, simulation, and decisioning belong to
  `Bank.Policies`, `Bank.Decisions`, and `Bank.Runtime` — not here.
  """

  import Ecto.Query

  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  @default_limit 50
  @max_limit 200

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
