defmodule Bank.Repo.Migrations.CreateScreeningRecords do
  @moduledoc """
  Screening records: the shared wallet-screening data model.

  Every source feed (OFAC, OpenSanctions, ScamSniffer, GraphSense,
  internal scoring) normalises its entries into this table. The
  `control_tier` column defines the runtime semantics:

    * `hard_block` — sanctions; automatic block
    * `challenge` — scam/phishing; manual review
    * `context` — attribution labels; enrichment only
    * `score_only` — internal scoring; advisory only

  The unique index on `(chain, normalised_address, source,
  source_record_id)` supports upsert-on-conflict for feed refreshes
  and guarantees that a single source entry maps to exactly one row.

  The lookup index on `(chain, normalised_address)` serves the
  runtime screening path: given a chain+address pair, return all
  matching records for precedence evaluation.
  """

  use Ecto.Migration

  def change do
    create table(:screening_records, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :chain, :text, null: false
      add :address, :text, null: false
      add :normalised_address, :text, null: false

      add :control_tier, :text, null: false
      add :source, :text, null: false
      add :source_record_id, :text, null: false

      add :category, :text
      add :reason, :text
      add :evidence_uri, :text
      add :metadata, :map, null: false, default: %{}

      add :first_seen_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      add :score, :decimal, precision: 10, scale: 6
      add :score_version, :text

      timestamps()
    end

    create constraint(:screening_records, :control_tier_valid,
             check: "control_tier IN ('hard_block','challenge','context','score_only')"
           )

    create constraint(:screening_records, :score_only_requires_score,
             check:
               "(control_tier != 'score_only') OR (control_tier = 'score_only' AND score IS NOT NULL)"
           )

    create unique_index(
             :screening_records,
             [:chain, :normalised_address, :source, :source_record_id],
             name: :screening_records_chain_addr_source_idx
           )

    create index(:screening_records, [:chain, :normalised_address],
             name: :screening_records_lookup_idx
           )

    create index(:screening_records, [:source])
    create index(:screening_records, [:control_tier])
    create index(:screening_records, [:expires_at])
  end
end
