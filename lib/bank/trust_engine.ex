defmodule Bank.TrustEngine do
  @moduledoc """
  Trust engine v0 — rule-based trust classification.

  Produces an `%TrustAssessment{}`-shaped classification for an
  `%AgentIntent{}`. The engine does **not** write to the DB; it returns
  an attribute map ready for `TrustAssessment.changeset/2`. Persistence
  is the caller's responsibility (typically the runtime evaluation
  worker), so the engine can be used for dry-run explanations without
  side effects.

  ## Trust states (v1 vocabulary)

    * `:trusted`    — counterparty has an effective trust assertion at
      `:trusted` whose scope covers the candidate intent.
    * `:sensitive`  — counterparty has a `:sensitive` assertion covering
      the candidate; sensitive wins over `:trusted` when both apply
      (the strictest label governs).
    * `:unknown`    — raw-address intents; or counterparty with no
      covering assertion; or every covering assertion is at `:unknown`.
    * `:conflicted` — two or more covering assertions disagree on the
      target level **and** none of them is broadly-scoped and recent
      enough to dominate.

  ## Confidence (v1 vocabulary)

    * `:high`   — at least one evidence artifact of kind
      `:signed_message`, `:contract_classification`, or
      `:prior_successful_transfer` supports the dominant assertion.
    * `:medium` — evidence exists but only as `:user_note` /
      `:external_lookup` / `:transaction_history`; or the dominant
      assertion is broadly-scoped and from an operator (`issued_by ==
      :user`).
    * `:low`    — no evidence backing the dominant assertion, or the
      intent is raw-address / unknown with nothing to say.

  `:conflicted` always caps confidence at `:low` regardless of
  evidence — two disagreeing operator assertions are the textbook case
  where the engine must surface the ambiguity rather than paper over it.

  ## Contradictions

  `contradictions.items` is a list of maps shaped like:

      %{
        "kind" => "scope_disagreement" | "level_disagreement" |
                  "assertion_expired" | "missing_evidence",
        "message" => "human-readable summary",
        "refs" => [uuid, ...]
      }

  The downstream routing (#17) reads `contradictions.items` to decide
  between `:hold` and `:approval_required` for conflicted outcomes.

  ## Raw-address intents

  An intent without a counterparty resolves to
  `derived_trust: :unknown, confidence: :low`. The rationale records
  `{"kind" => "raw_address", ...}` so the operator UI can surface
  "this address has no resolved identity" explicitly rather than
  assuming the address is unsafe.
  """

  alias Bank.Counterparties
  alias Bank.Counterparties.{Counterparty, EvidenceArtifact, TrustAssertion}
  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  @type t :: %{
          derived_trust: :trusted | :sensitive | :unknown | :conflicted,
          confidence: :low | :medium | :high,
          contradictions: %{String.t() => [map()]},
          supporting_assertion_ids: [Ecto.UUID.t()],
          supporting_evidence_ids: [Ecto.UUID.t()],
          rationale: map(),
          generated_at: DateTime.t(),
          generated_by: :runtime
        }

  @strong_evidence_kinds [
    :signed_message,
    :contract_classification,
    :prior_successful_transfer
  ]

  @doc """
  Classify an intent.

  Options:

    * `:now` — override the clock (default `DateTime.utc_now/0`). The
      clock governs assertion expiry, not DB writes.
    * `:assertions` — supply the candidate trust-assertion set rather
      than loading from the Repo; used by tests and by the runtime
      when it already holds the set.
    * `:evidence` — supply the candidate evidence set rather than
      loading from the Repo.
  """
  @spec classify(AgentIntent.t(), keyword()) :: t()
  def classify(%AgentIntent{} = intent, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    do_classify(intent, now, opts)
  end

  # --- classification pipeline ---------------------------------------

  defp do_classify(%AgentIntent{target_counterparty_id: nil} = intent, now, _opts) do
    rationale = %{
      "kind" => "raw_address",
      "message" =>
        "intent targets a raw on-chain address; no resolved counterparty or assertions are available.",
      "target" => intent.target_raw_address
    }

    build_claim(%{
      derived_trust: :unknown,
      confidence: :low,
      contradictions: [],
      supporting_assertion_ids: [],
      supporting_evidence_ids: [],
      rationale: rationale,
      generated_at: now
    })
  end

  defp do_classify(%AgentIntent{} = intent, now, opts) do
    cp = load_counterparty(intent.target_counterparty_id)
    assertions = load_assertions(cp, intent, now, opts)
    evidence = load_evidence(cp, intent, opts)

    covering = Enum.filter(assertions, &covers?(&1, intent))

    case covering do
      [] -> no_assertion_result(cp, intent, now, evidence)
      _ -> dominant_result(cp, intent, covering, evidence, now)
    end
  end

  # --- no assertion branch -------------------------------------------

  defp no_assertion_result(cp, intent, now, evidence) do
    rationale = %{
      "kind" => "no_covering_assertion",
      "message" =>
        "counterparty #{inspect(cp && cp.name)} has no effective trust assertion covering chain=#{intent.chain}, asset=#{intent.asset}.",
      "counterparty_id" => cp && cp.id
    }

    # Evidence alone never produces a level above `:unknown`; it is
    # recorded so the UI can say "we know something, just not enough
    # to raise trust".
    build_claim(%{
      derived_trust: :unknown,
      confidence: :low,
      contradictions: [
        %{
          "kind" => "missing_evidence",
          "message" => "no trust assertion covers this candidate.",
          "refs" => []
        }
      ],
      supporting_assertion_ids: [],
      supporting_evidence_ids: Enum.map(evidence, & &1.id),
      rationale: rationale,
      generated_at: now
    })
  end

  # --- dominant-assertion branch -------------------------------------

  defp dominant_result(cp, _intent, covering, evidence, now) do
    grouped = Enum.group_by(covering, & &1.level)
    levels = Map.keys(grouped)

    {level, contradictions} = resolve_level(levels, grouped)
    dominant = dominant_assertion(level, grouped)

    supporting_evidence = supporting_evidence_for(dominant, evidence)
    confidence = compute_confidence(level, dominant, supporting_evidence, contradictions)

    rationale = %{
      "kind" => "dominant_assertion",
      "message" =>
        "counterparty #{inspect(cp && cp.name)} classified #{level} by #{length(covering)} covering assertion(s).",
      "counterparty_id" => cp && cp.id,
      "scope" => (dominant && dominant.scope) || %{},
      "issued_by" => dominant && to_string(dominant.issued_by),
      "rationale" => dominant && dominant.rationale
    }

    build_claim(%{
      derived_trust: level,
      confidence: confidence,
      contradictions: contradictions,
      supporting_assertion_ids: Enum.map(covering, & &1.id),
      supporting_evidence_ids: Enum.map(supporting_evidence, & &1.id),
      rationale: rationale,
      generated_at: now
    })
  end

  # Pick the representative assertion for rationale purposes. For a
  # non-conflicted level, we want an assertion at that level; for a
  # conflicted outcome, we prefer the most recent assertion seen so
  # the rationale links to actual evidence in the UI.
  defp dominant_assertion(:conflicted, grouped) do
    grouped
    |> Map.values()
    |> List.flatten()
    |> Enum.max_by(& &1.issued_at, DateTime, fn -> nil end)
  end

  defp dominant_assertion(level, grouped) do
    grouped
    |> Map.get(level, [])
    |> Enum.at(0)
  end

  # Strictest level wins. :sensitive dominates :trusted; :conflicted
  # triggers when the covering set disagrees on a non-conservative
  # direction (both trusted + sensitive, or trusted + unknown with
  # matched scope).
  defp resolve_level([single], _grouped), do: {single, []}

  defp resolve_level(levels, grouped) do
    level =
      cond do
        :conflicted in levels -> :conflicted
        :sensitive in levels and :trusted in levels -> :conflicted
        :sensitive in levels -> :sensitive
        :unknown in levels and :trusted in levels -> :conflicted
        :trusted in levels -> :trusted
        :unknown in levels -> :unknown
      end

    refs =
      grouped
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.id)

    contradictions =
      if level == :conflicted do
        [
          %{
            "kind" => "level_disagreement",
            "message" =>
              "covering assertions disagree on level: #{levels |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")}.",
            "refs" => refs
          }
        ]
      else
        []
      end

    {level, contradictions}
  end

  # --- confidence ----------------------------------------------------

  defp compute_confidence(:conflicted, _dominant, _evidence, _contradictions), do: :low

  defp compute_confidence(_level, %TrustAssertion{} = dominant, evidence, _contradictions) do
    has_strong_evidence? = Enum.any?(evidence, &(&1.kind in @strong_evidence_kinds))

    cond do
      has_strong_evidence? ->
        :high

      evidence != [] ->
        :medium

      # Broadly-scoped operator assertion with no supporting evidence
      # still merits `:medium` — a human explicitly vouched.
      dominant.issued_by == :user and (dominant.scope == nil or dominant.scope == %{}) ->
        :medium

      true ->
        :low
    end
  end

  # --- scope coverage -------------------------------------------------

  # An assertion covers a candidate if every scope key matches the
  # candidate's fields. Unknown scope keys are permissive (same policy
  # as `Bank.Policies.applicable?/2`) so the engine keeps working as
  # future scope keys land.
  defp covers?(%TrustAssertion{scope: scope}, %AgentIntent{} = intent) do
    scope = scope || %{}

    Enum.all?(scope, fn {k, v} ->
      scope_matches?(to_string(k), v, intent)
    end)
  end

  defp scope_matches?("chain", expected, %AgentIntent{chain: actual}), do: actual == expected
  defp scope_matches?("asset", expected, %AgentIntent{asset: actual}), do: actual == expected

  defp scope_matches?("amount_ceiling", ceiling, %AgentIntent{amount: amount})
       when not is_nil(amount) do
    case decimal(ceiling) do
      {:ok, d} -> Decimal.compare(amount, d) != :gt
      :error -> true
    end
  end

  defp scope_matches?(_unknown_key, _value, _intent), do: true

  defp decimal(%Decimal{} = d), do: {:ok, d}

  defp decimal(v) when is_binary(v) do
    case Decimal.parse(v) do
      {d, ""} -> {:ok, d}
      _ -> :error
    end
  end

  defp decimal(v) when is_integer(v) or is_float(v), do: {:ok, Decimal.new(to_string(v))}
  defp decimal(_), do: :error

  # --- data loading --------------------------------------------------

  defp load_counterparty(nil), do: nil

  defp load_counterparty(id) do
    case Repo.get(Counterparty, id) do
      nil -> nil
      %Counterparty{} = cp -> cp
    end
  end

  defp load_assertions(cp, _intent, _now, opts) do
    case Keyword.fetch(opts, :assertions) do
      {:ok, assertions} ->
        assertions

      :error ->
        case cp do
          %Counterparty{id: id} -> Counterparties.effective_trust_assertions("counterparty", id)
          _ -> []
        end
    end
  end

  defp load_evidence(%Counterparty{id: id}, _intent, opts) do
    case Keyword.fetch(opts, :evidence) do
      {:ok, list} -> list
      :error -> fetch_evidence(id)
    end
  end

  defp load_evidence(nil, _intent, _opts), do: []

  defp fetch_evidence(cp_id) do
    import Ecto.Query

    from(e in EvidenceArtifact,
      where: e.subject_type == "counterparty" and e.subject_id == ^cp_id,
      where: is_nil(e.supersedes_id),
      order_by: [desc: e.captured_at, desc: e.id]
    )
    |> Repo.all()
  end

  # --- supporting evidence selection ---------------------------------

  # Evidence that was either explicitly referenced by the assertion
  # (`evidence_ids`) or attached to the same subject. Caps the list at
  # the most recent 10 to keep the claim compact.
  defp supporting_evidence_for(%TrustAssertion{evidence_ids: ids}, evidence)
       when is_list(ids) and ids != [] do
    referenced = MapSet.new(ids)
    evidence |> Enum.filter(&MapSet.member?(referenced, &1.id)) |> Enum.take(10)
  end

  defp supporting_evidence_for(_assertion, evidence), do: Enum.take(evidence, 10)

  # --- build ---------------------------------------------------------

  defp build_claim(map) do
    map
    |> Map.put(:generated_by, :runtime)
    |> Map.update!(:contradictions, fn items -> %{"items" => items} end)
  end
end
