defmodule BankWeb.API.V1.CounterpartyJSON do
  @moduledoc """
  JSON renderers for `/v1/counterparties*`, `/v1/address_labels/:id`,
  and `/v1/trust_assertions`.

  The shapes here are the external contract, not a schema mirror. Keep
  additions additive: add new fields if needed, but do not remove or
  rename existing ones without coordination with the adapter / UI.

  Shape highlights:

    * A **counterparty** rendered via `show/1` / `show!/1` includes
      `active_address_labels`, `effective_trust_assertions`, and
      `evidence` when those preloads are loaded. The list endpoint
      emits the bare counterparty object.
    * A **trust_assertion** carries a `coarse: true` flag when it is
      unscoped and `trusted` — an operational hint matching the
      runtime-flow spec. The cache on the counterparty (rendered as
      `current_trust_level`) is what UI lists show.
  """

  alias Bank.Counterparties.{AddressLabel, Counterparty, EvidenceArtifact, TrustAssertion}

  @doc "Paged `GET /v1/counterparties` envelope."
  def index(%{entries: entries, next_cursor: cursor}) do
    %{
      data: Enum.map(entries, &counterparty/1),
      page: %{next_cursor: cursor}
    }
  end

  @doc """
  Single-counterparty payload. Expects the counterparty preloaded with
  `address_labels`, `trust_assertions`, and `evidence_artifacts`
  (`Bank.Counterparties.preload_counterparty/1`).
  """
  def show(%{counterparty: %Counterparty{} = cp}) do
    %{data: counterparty_with_preloads(cp)}
  end

  @doc """
  `POST /v1/counterparties` / `PATCH /v1/counterparties/:id` payload —
  returns the counterparty with the same preloaded shape as `show/1`.
  """
  def counterparty_created(%{counterparty: %Counterparty{} = cp}) do
    %{data: counterparty_with_preloads(cp)}
  end

  @doc "`POST /v1/counterparties/:id/addresses` payload."
  def address_label_attached(%{address_label: %AddressLabel{} = label}) do
    %{data: address_label(label)}
  end

  @doc "`PATCH /v1/address_labels/:id` payload."
  def address_label_updated(%{address_label: %AddressLabel{} = label}) do
    %{data: address_label(label)}
  end

  @doc "`POST /v1/counterparties/:id/evidence` payload."
  def evidence_pinned(%{evidence: %EvidenceArtifact{} = evidence}) do
    %{data: evidence_artifact(evidence)}
  end

  @doc "`POST /v1/trust_assertions` payload."
  def trust_assertion_issued(%{trust_assertion: %TrustAssertion{} = assertion}) do
    %{data: trust_assertion(assertion)}
  end

  # --- entity renderers --------------------------------------------------

  @doc false
  def counterparty(%Counterparty{} = cp) do
    %{
      id: cp.id,
      name: cp.name,
      ownership_context: cp.ownership_context,
      notes: cp.notes,
      active: cp.active,
      current_trust_level: cp.current_trust_level,
      created_by: cp.created_by,
      inserted_at: cp.inserted_at,
      updated_at: cp.updated_at
    }
  end

  defp counterparty_with_preloads(%Counterparty{} = cp) do
    cp
    |> counterparty()
    |> Map.put(:active_address_labels, preload_labels(cp))
    |> Map.put(:effective_trust_assertions, preload_assertions(cp))
    |> Map.put(:evidence, preload_evidence(cp))
  end

  defp preload_labels(%Counterparty{address_labels: %Ecto.Association.NotLoaded{}}), do: nil

  defp preload_labels(%Counterparty{address_labels: labels}) when is_list(labels),
    do: Enum.map(labels, &address_label/1)

  defp preload_assertions(%Counterparty{trust_assertions: %Ecto.Association.NotLoaded{}}), do: nil

  defp preload_assertions(%Counterparty{trust_assertions: assertions}) when is_list(assertions),
    do: Enum.map(assertions, &trust_assertion/1)

  defp preload_evidence(%Counterparty{evidence_artifacts: %Ecto.Association.NotLoaded{}}), do: nil

  defp preload_evidence(%Counterparty{evidence_artifacts: evidence}) when is_list(evidence),
    do: Enum.map(evidence, &evidence_artifact/1)

  @doc false
  def address_label(%AddressLabel{} = label) do
    %{
      id: label.id,
      counterparty_id: label.counterparty_id,
      chain: label.chain,
      address: label.address,
      alias: label.alias,
      role: label.role,
      verified: label.verified,
      retired_at: label.retired_at,
      inserted_at: label.inserted_at,
      updated_at: label.updated_at
    }
  end

  @doc false
  def evidence_artifact(%EvidenceArtifact{} = artifact) do
    %{
      id: artifact.id,
      subject_type: artifact.subject_type,
      subject_id: artifact.subject_id,
      kind: artifact.kind,
      source: artifact.source,
      content_uri: artifact.content_uri,
      payload_hash: artifact.payload_hash,
      weight: artifact.weight,
      captured_at: artifact.captured_at,
      captured_by: artifact.captured_by,
      supersedes_id: artifact.supersedes_id,
      inserted_at: artifact.inserted_at
    }
  end

  @doc false
  def trust_assertion(%TrustAssertion{} = assertion) do
    scope = assertion.scope || %{}

    %{
      id: assertion.id,
      subject: %{type: assertion.subject_type, id: assertion.subject_id},
      level: assertion.level,
      scope: scope,
      rationale: assertion.rationale,
      evidence_ids: assertion.evidence_ids,
      issued_at: assertion.issued_at,
      issued_by: assertion.issued_by,
      expires_at: assertion.expires_at,
      superseded_at: assertion.superseded_at,
      supersedes_id: assertion.supersedes_id,
      # Flag matches the runtime-flow doc: unscoped `trusted` is
      # accepted but surfaced as a coarse assertion so the UI can
      # warn / ask for a tighter scope.
      coarse: coarse?(assertion, scope)
    }
  end

  defp coarse?(%TrustAssertion{level: :trusted}, scope), do: map_size(scope) == 0
  defp coarse?(_assertion, _scope), do: false
end
