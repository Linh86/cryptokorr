# Wallet Screening Feed Freshness — Operator Runbook

## Overview

CryptoBank screens destination addresses against multiple external
feeds before allowing execution. Each feed has a freshness threshold;
when a feed is stale, missing, or failing, the system degrades toward
caution rather than silently proceeding with outdated data.

## Feed inventory and thresholds

| Source          | Control tier  | Stale after | Severity | What it means when stale |
|-----------------|--------------|-------------|----------|--------------------------|
| `ofac`          | `hard_block` | 24 hours    | **high** | OFAC sanctions data is outdated. New sanctioned addresses may not be blocked. |
| `opensanctions` | `hard_block` | 24 hours    | **high** | OpenSanctions data is outdated. Same risk as stale OFAC. |
| `scamsniffer`   | `challenge`  | 48 hours    | warning  | ScamSniffer phishing data is outdated. New scam addresses may not trigger review. |
| `etherscamdb`   | `challenge`  | 48 hours    | warning  | EtherScamDB scam data is outdated. Same risk as stale ScamSniffer. |
| `btc_abuse`     | `challenge`  | 48 hours    | warning  | BTC abuse data is outdated. New BTC scam addresses may not trigger review. |
| `graphsense`    | `context`    | 7 days      | info     | GraphSense attribution data is outdated. Operator context may be incomplete. |
| `internal_scoring` | `score_only` | 7 days  | info     | Internal scoring data is outdated. Advisory signals may be stale. |

## How to inspect feed freshness

### From the Elixir console (IEx)

```elixir
# All sources, sorted by severity
Bank.WalletScreening.FeedHealth.all()

# Single source
Bank.WalletScreening.FeedHealth.get("ofac")

# Only stale/failed/unknown
Bank.WalletScreening.FeedHealth.stale_sources()

# Only high-severity stale sources
Bank.WalletScreening.FeedHealth.stale_sources_by_severity(:high)
```

Each source health state includes:
- `status` — `:fresh`, `:stale`, `:failed`, or `:unknown`
- `severity` — `:high`, `:warning`, or `:info`
- `last_success_at` — when the last successful ingestion completed
- `last_failure_at` / `last_failure_reason` — when and why the last failure occurred
- `last_ingested` / `last_skipped` — record counts from the last run

## How to refresh feeds

### Manual refresh from IEx

```elixir
# Sanctions
Bank.WalletScreening.Ingestion.ingest_ofac()
Bank.WalletScreening.Ingestion.ingest_opensanctions()

# Scam feeds
Bank.WalletScreening.Ingestion.ingest_scamsniffer()
Bank.WalletScreening.Ingestion.ingest_etherscamdb()
Bank.WalletScreening.Ingestion.ingest_btc_abuse()

# Context
Bank.WalletScreening.Ingestion.ingest_graphsense()

# Scoring (pass results directly)
Bank.WalletScreening.Ingestion.ingest_scoring(scoring_results)
```

### Override feed URL

Every feed URL is configurable. To point at a mirror or local copy:

```elixir
Bank.WalletScreening.Ingestion.ingest_ofac(url: "https://mirror.example.com/sdn_advanced.xml")
```

Or update the application config:

```elixir
Application.put_env(:bank, Bank.WalletScreening.Ingestion,
  ofac_url: "https://mirror.example.com/sdn_advanced.xml",
  req_options: []
)
```

## What stale data means operationally

### Sanctions (high severity)

Stale OFAC or OpenSanctions data means newly sanctioned addresses
may not be blocked. This is a legal and compliance risk.

**Action required:**
1. Investigate why the feed is failing (check `last_failure_reason`).
2. If the upstream source is down, check their status page.
3. If the URL has changed, update the config.
4. If the issue persists, consider pausing autonomous execution
   until sanctions data is refreshed.

### Scam feeds (warning severity)

Stale scam feed data means newly reported phishing/scam addresses
may not trigger operator review. Sanctions blocking still works;
only the challenge layer is degraded.

**Action required:**
1. Check `last_failure_reason` for HTTP errors or parse failures.
2. If the upstream repository has moved, update the URL.
3. Manual screening of suspicious destinations may be needed until
   the feed is refreshed.

### Context and scoring (info severity)

Stale context or scoring data means operator enrichment and
advisory signals may be incomplete. Neither layer blocks or
challenges transactions on its own.

**Action:** Investigate and refresh when convenient. No urgent
operational risk.

## Feed URL rotation

If an upstream feed URL changes or a source is deprecated:

1. Update the URL in `config/runtime.exs` or via
   `Application.put_env/3`.
2. Run a manual refresh to verify the new URL works.
3. Check `FeedHealth.get(source)` to confirm the status is `:fresh`.
4. If removing a source entirely, run
   `Bank.WalletScreening.delete_expired_records(source, DateTime.utc_now())`
   to clean up stale records.

## Disabling a feed

To temporarily disable a feed without removing its data:

1. Set the feed URL to `nil` in config (BTC abuse already requires
   an explicit URL).
2. The ingestion function will return
   `{:error, :*_feed_url_not_configured}`.
3. Existing screening records remain active until they expire or are
   cleaned up.
