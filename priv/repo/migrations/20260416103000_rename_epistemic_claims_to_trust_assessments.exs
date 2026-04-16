defmodule Bank.Repo.Migrations.RenameEpistemicClaimsToTrustAssessments do
  @moduledoc """
  Renames the old epistemic-claim storage to the product-owned trust
  assessment naming.

  Earlier local databases may already have run the original migrations
  before the repo terminology was updated. This migration reconciles
  those installations by renaming the existing table, indexes,
  constraints, and referencing columns when the old names are present.

  Fresh databases created from the current migration set already use
  the new names, so every statement here is guarded and becomes a
  no-op in that case.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('public.epistemic_claims') IS NOT NULL
         AND to_regclass('public.trust_assessments') IS NULL THEN
        ALTER TABLE epistemic_claims RENAME TO trust_assessments;
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'agent_intents'
             AND column_name = 'current_epistemic_claim_id'
         )
         AND NOT EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'agent_intents'
             AND column_name = 'current_trust_assessment_id'
         ) THEN
        ALTER TABLE agent_intents
          RENAME COLUMN current_epistemic_claim_id TO current_trust_assessment_id;
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'decision_envelopes'
             AND column_name = 'epistemic_claim_id'
         )
         AND NOT EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'decision_envelopes'
             AND column_name = 'trust_assessment_id'
         ) THEN
        ALTER TABLE decision_envelopes
          RENAME COLUMN epistemic_claim_id TO trust_assessment_id;
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
           SELECT 1 FROM pg_constraint WHERE conname = 'epistemic_claims_pkey'
         ) THEN
        ALTER TABLE trust_assessments
          RENAME CONSTRAINT epistemic_claims_pkey TO trust_assessments_pkey;
      END IF;

      IF EXISTS (
           SELECT 1 FROM pg_constraint WHERE conname = 'epistemic_claims_intent_id_fkey'
         ) THEN
        ALTER TABLE trust_assessments
          RENAME CONSTRAINT epistemic_claims_intent_id_fkey TO trust_assessments_intent_id_fkey;
      END IF;

      IF EXISTS (
           SELECT 1 FROM pg_constraint WHERE conname = 'epistemic_claims_supersedes_id_fkey'
         ) THEN
        ALTER TABLE trust_assessments
          RENAME CONSTRAINT epistemic_claims_supersedes_id_fkey TO trust_assessments_supersedes_id_fkey;
      END IF;

      IF EXISTS (
           SELECT 1
           FROM pg_constraint
           WHERE conname = 'decision_envelopes_epistemic_claim_id_fkey'
         ) THEN
        ALTER TABLE decision_envelopes
          RENAME CONSTRAINT decision_envelopes_epistemic_claim_id_fkey
          TO decision_envelopes_trust_assessment_id_fkey;
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF to_regclass('public.epistemic_claims_intent_id_index') IS NOT NULL
         AND to_regclass('public.trust_assessments_intent_id_index') IS NULL THEN
        ALTER INDEX epistemic_claims_intent_id_index
          RENAME TO trust_assessments_intent_id_index;
      END IF;

      IF to_regclass('public.epistemic_claims_intent_current_idx') IS NOT NULL
         AND to_regclass('public.trust_assessments_intent_current_idx') IS NULL THEN
        ALTER INDEX epistemic_claims_intent_current_idx
          RENAME TO trust_assessments_intent_current_idx;
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF to_regclass('public.trust_assessments_intent_id_index') IS NOT NULL
         AND to_regclass('public.epistemic_claims_intent_id_index') IS NULL THEN
        ALTER INDEX trust_assessments_intent_id_index
          RENAME TO epistemic_claims_intent_id_index;
      END IF;

      IF to_regclass('public.trust_assessments_intent_current_idx') IS NOT NULL
         AND to_regclass('public.epistemic_claims_intent_current_idx') IS NULL THEN
        ALTER INDEX trust_assessments_intent_current_idx
          RENAME TO epistemic_claims_intent_current_idx;
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
           SELECT 1 FROM pg_constraint WHERE conname = 'trust_assessments_pkey'
         ) THEN
        ALTER TABLE trust_assessments
          RENAME CONSTRAINT trust_assessments_pkey TO epistemic_claims_pkey;
      END IF;

      IF EXISTS (
           SELECT 1 FROM pg_constraint WHERE conname = 'trust_assessments_intent_id_fkey'
         ) THEN
        ALTER TABLE trust_assessments
          RENAME CONSTRAINT trust_assessments_intent_id_fkey TO epistemic_claims_intent_id_fkey;
      END IF;

      IF EXISTS (
           SELECT 1 FROM pg_constraint WHERE conname = 'trust_assessments_supersedes_id_fkey'
         ) THEN
        ALTER TABLE trust_assessments
          RENAME CONSTRAINT trust_assessments_supersedes_id_fkey TO epistemic_claims_supersedes_id_fkey;
      END IF;

      IF EXISTS (
           SELECT 1
           FROM pg_constraint
           WHERE conname = 'decision_envelopes_trust_assessment_id_fkey'
         ) THEN
        ALTER TABLE decision_envelopes
          RENAME CONSTRAINT decision_envelopes_trust_assessment_id_fkey
          TO decision_envelopes_epistemic_claim_id_fkey;
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'decision_envelopes'
             AND column_name = 'trust_assessment_id'
         )
         AND NOT EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'decision_envelopes'
             AND column_name = 'epistemic_claim_id'
         ) THEN
        ALTER TABLE decision_envelopes
          RENAME COLUMN trust_assessment_id TO epistemic_claim_id;
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'agent_intents'
             AND column_name = 'current_trust_assessment_id'
         )
         AND NOT EXISTS (
           SELECT 1
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'agent_intents'
             AND column_name = 'current_epistemic_claim_id'
         ) THEN
        ALTER TABLE agent_intents
          RENAME COLUMN current_trust_assessment_id TO current_epistemic_claim_id;
      END IF;
    END
    $$;
    """)

    execute("""
    DO $$
    BEGIN
      IF to_regclass('public.trust_assessments') IS NOT NULL
         AND to_regclass('public.epistemic_claims') IS NULL THEN
        ALTER TABLE trust_assessments RENAME TO epistemic_claims;
      END IF;
    END
    $$;
    """)
  end
end
