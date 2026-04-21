# Bank v0.1 Decision Memo

## Thesis

`Bank v0.1` is the internal codename for a non-custodial AI treasury runtime. It is not a bank, not a wallet, and not a custody provider. It is a hosted control plane that allows AI agents to participate in money operations without ever receiving unconstrained control over user funds.

The core thesis is simple: AI may decide, but money only moves inside boundaries defined by the user and enforced by the runtime. Those boundaries are not a cosmetic permission layer. They are the product itself.

This means the system is designed around three commitments from day one. First, the user keeps control of keys and account ownership. Second, every proposed money action is evaluated against explicit rules before execution. Third, every decision and execution path must be inspectable after the fact.

Externally, the product should be positioned as a safe layer between AI and money, or as a non-custodial AI treasury runtime. Internally, `Bank v0.1` is a useful codename because it captures the ambition to make AI-driven money operations reliable, constrained, and operationally legible.

## Problem

Today, AI agents are stuck between two bad options. In the first option, they are weak and purely advisory. They can recommend a payment, transfer, or swap, but a human still has to manually drive the process end to end. This limits the real utility of agents in operational finance.

In the second option, agents are given too much freedom. They can generate raw transaction requests, interact with unfamiliar contracts, or trigger wallet operations with very little structural control. This creates a trust gap that most serious users will not accept, especially when funds are on-chain and errors are irreversible.

Crypto and stablecoin operations are the right first wedge because they are programmable, on-chain, auditable, and API-native. The core workflows are already digital and composable. There is no need to invent a new money rail before creating a safer runtime around existing rails.

The first customer is not mainstream retail. The first customer is a power user who already operates on-chain and wants automation without surrendering keys. This user is willing to define trusted counterparties, explicit limits, and approval thresholds if doing so allows repetitive financial operations to run with less manual effort and more confidence.

## Product Definition

The product is a control plane for AI-driven money operations. It sits between an agent that proposes actions and the execution path that can move assets. The product does not ask users to trust the model directly. It asks them to trust a structured decision system that constrains what the model can cause to happen.

The runtime makes decisions using three layers.

The first layer is policy. Policy answers the question: what is allowed? It encodes allowed assets, chains, counterparties, routers, amount limits, slippage ceilings, time windows, and autonomy thresholds.

The second layer is the trust layer. It answers the question: how sure are we that we understand who or what this action touches? It reasons about address identity, counterparty trust, protocol classification, supporting evidence, and contradictions or uncertainty in the available context.

The third layer is execution guardrails. It answers the question: what can actually be signed and executed, even if other software behaves unexpectedly? These guardrails belong at the account-permission and smart-account level, where practical limits can still be enforced if upstream systems fail.

For v1, the trust model should be intentionally simple and operational:

- `trusted`: known counterparty or address with sufficient evidence and policy coverage
- `sensitive`: known entity that is allowed, but requires additional care because of amount, asset, routing, or business importance
- `unknown`: not enough evidence to treat the target as safe
- `conflicted`: contradictory evidence or unresolved identity mismatch

This structure gives the product a practical posture. The system should not only decide whether an action is technically permitted. It should also decide whether it is sufficiently understood to be safely automated.

## Architecture Decision

The backend control plane should be built in Phoenix. Phoenix is the right place for the authoritative runtime because this product is primarily an orchestration, safety, audit, and decision system. The backend must evaluate policies, track counterparties, manage approvals, coordinate execution queues, and provide realtime visibility. Those strengths align well with Phoenix and the broader Elixir runtime model.

Postgres should be the source of truth. It should store policies, counterparties, address labels, evidence artifacts, trust assertions, queued decisions, audit events, execution state, and approval history. This product needs durable, queryable operational truth more than it needs experimental storage layers. Postgres is the most boring and reliable choice, which is exactly what a money-adjacent control plane should prefer.

Oban and PubSub should provide the operational backbone for jobs and realtime behavior. Oban can manage scheduled actions, retries, quote refreshes, queued approvals, cooldown timers, and execution follow-ups. PubSub can drive operator updates in the web application so that dashboards, approval queues, and risk changes reflect system state as it changes.

A TypeScript adapter layer should handle chain-specific execution work. This includes EVM account abstraction, bundler integrations, quote providers, simulation vendors, wallet-specific behavior, and chain-facing transaction assembly. This is where the ecosystem is strongest today, and there is no advantage in forcing Phoenix to own the most vendor-dependent and chain-specific logic directly.

Solidity should be used sparingly and only where on-chain guardrails are necessary. Examples include smart-account permission modules, spend limits, target restrictions, or revocable delegation primitives. Complex decisioning should not move on-chain. On-chain code should be minimal, enforceable, and auditable.

This architecture is better than an all-in TypeScript backend because the product is not just a chain integration service. It is a decisioning and control system that benefits from strong concurrency, durable workflows, and operational clarity. It is better than an all-in Elixir chain stack because the EVM tooling ecosystem for account abstraction, quoting, bundlers, and wallet integrations is more mature in TypeScript. It is better than pushing policy and simulation logic on-chain because those concerns change quickly, require richer context, and are too expensive and rigid to express entirely inside contracts.

## Runtime Flow

The canonical runtime flow is:

`agent intent -> policy evaluation -> evidence/trust lookup -> simulation -> risk tiering -> auto-exec / hold / approval required / block -> audit trail`

The LLM does not produce raw calldata as the source of truth. It produces a structured intent. An intent expresses what the agent wants to accomplish, not the final low-level transaction bytes that should be executed.

Phoenix is the decision authority. It receives the intent, checks it against policy, looks up trust and evidence, decides whether simulation is acceptable, assigns a risk tier, and chooses the next state. The TypeScript adapter is the chain execution specialist. It turns an approved execution plan into chain-compatible actions and reports execution outcomes back into the control plane.

Every action must be replayable. At any later time, an operator should be able to inspect the original intent, the active policy, the trust state, the simulation output, the resulting decision, the approval path if any, and the final execution result. If a user asks why money moved, the system should answer with a trail, not a shrug.

## Core Product Modules

### Counterparties and Address Book

The product needs a first-class counterparty model rather than a flat list of addresses. A counterparty may have one or more addresses, labels, notes, ownership context, and supporting evidence. This lets the system reason at the business level, not just at the hex-string level.

### Policy Engine

The policy engine defines the operational box in which automation is allowed. It should support allowed assets, chains, counterparties, routers, amount limits, daily or rolling spend caps, slippage limits, time windows, and autonomy tiers.

### Trust Engine

The trust engine determines how confident the system is in the identity and context of an action. It should store evidence artifacts, derive trust assertions, surface contradictions, and produce a structured claim with confidence and uncertainty rather than a binary yes or no.

### Simulation Engine

The simulation layer should return predicted balance changes, gas or fee expectations, routing information, expected output, slippage exposure, and notable failure conditions. The purpose is not perfect foresight. The purpose is enough visibility to reject actions that are allowed in theory but unsafe in context.

### Decision Engine

The decision engine combines policy, trust, and simulation into one action state. In v1, the main outcomes are `auto-exec`, `hold`, `approval required`, and `blocked`.

### Audit and Replay

Every important event should be captured in an append-only audit trail. This includes policy updates, counterparty changes, evidence changes, intent submissions, simulation results, decisions, approvals, execution attempts, and final outcomes. Replay is a product feature, not just an internal debug tool.

### Security Console

Operators need a fast way to pause automation, revoke delegations, inspect pending risk, and understand what the runtime is currently allowed to do. This is the operational safety surface of the product.

## Core Types And API Surface

The domain should be expressed through a small, explicit set of core types:

- `AgentIntent`
- `Counterparty`
- `AddressLabel`
- `EvidenceArtifact`
- `TrustAssertion`
- `TrustAssessment`
- `PolicyRule`
- `SimulationReport`
- `DecisionEnvelope`
- `ExecutionPlan`
- `AuditEvent`

The external API surface should remain narrow and operational:

- submit or evaluate an intent
- simulate an intent
- list and manage counterparties and labels
- update policy
- approve or reject queued actions
- execute an approved plan
- inspect audit and replay data
- trigger emergency pause or delegation revoke actions

The API should be explicit, not generic. Finance-facing systems benefit from small, well-named, reviewable endpoints rather than broad dynamic action surfaces.

## MVP Product Scope

The MVP should ship as a desktop-first web control tower plus an API-first backend. The web app builds trust and control. The API enables agent integrations and future automation surfaces.

The MVP should include:

- wallet or smart-account connection
- safe address labeling
- sanctioned and risky-wallet screening on destination addresses
- user-curated counterparties with evidence and notes
- stablecoin transfers
- recurring or triggered payment operations
- limited whitelist-only swaps
- tiered autonomy
- approval queue
- operator alerts and approvals via Telegram bot
- full decision audit
- emergency pause and delegation revoke

The MVP should not include:

- fiat rails
- centralized exchange integrations
- broad DeFi strategies
- open-ended contract interaction
- bridging
- full multi-chain launch
- retail neobank experience
- free-form chat-driven transaction authoring without policy-bound intents

The product should be architected as chain-agnostic, but only one production EVM L2 should go live in v1. The default first live chain should be Base. The default first-class asset should be USDC.

This scope is intentionally narrow. The goal is not to prove that an agent can do everything with money. The goal is to prove that an agent can safely and usefully operate inside a constrained treasury runtime.

## Web App Surface

The v1 web application should include six primary surfaces.

The Dashboard should show balances, recent decisions, pending approvals, alerts, and current runtime status.

The Counterparties or Address Book view should let users label addresses, group them into counterparties, inspect trust state, and review the evidence behind that trust.

The Policies view should let users define what is allowed and under what thresholds autonomy can occur.

The Action Queue should show what the agent wants to do, what the simulation predicts, what risk tier was assigned, and what action is now required from the operator.

The Audit and Replay view should explain why an action executed, why it was blocked, and what evidence, policy, and simulation data informed that outcome.

The Security Console should provide pause, revoke, delegation visibility, and operational safety controls.

This web app is not a custody experience. It is a trust, control, and observability interface for an execution runtime.

## Operator Messaging Surface

Implemented by epic #54.

The MVP includes a Telegram bot as a thin operator surface on top of the
control plane.

The bot should not replace the web console. It should shorten response
time when a human decision is needed.

The Telegram bot supports:

- alert delivery for pending approvals, runtime pause / resume, revoke
  failures, execution outcomes, and sanctions / scam hits
- approve or reject of queued actions
- runtime status and queue summary commands
- deep links back to replay or audit in the web control tower

The Telegram bot does not support:

- free-form transaction authoring
- policy editing
- direct bypass of the approval queue
- unaudited operator actions

## Address And Wallet Risk Intelligence

See epic #55.

Safe address labeling in MVP should not rely on user curation alone. The
runtime should combine curated counterparties with external wallet-risk
intelligence.

The decision boundary should be layered:

- **Hard block** for exact sanctions hits from OFAC and OpenSanctions
- **Warning / challenge** for scam or phishing signals from community
  feeds like ScamSniffer, EtherScamDB, and BTC-specific abuse feeds
- **Context / labeling** from GraphSense tagpacks and other public
  attribution sources
- **Internal scoring only** from research datasets such as Elliptic++
  and similar modeling inputs; model output alone should not create a
  hard block

This layering matters because the product should be able to say not only
"this transfer is denied," but also whether it was denied for legal
sanctions reasons, challenged for scam risk, or merely elevated for
human review due to suspicious context.

## Design Principles

The product should follow a small set of design principles that remain stable even as the implementation evolves.

- append-only audit instead of mutable history
- explicit assumptions on decisions instead of hidden heuristics
- uncertainty ranges instead of fake precision
- evidence lineage instead of unsupported trust claims
- accountable decision ownership instead of ambiguous system behavior
- challenge and replay paths instead of opaque automation

These principles matter because the hardest question in AI finance is not only whether the system can act. It is whether the system can justify why it acted, or why it refused to act, in a way that users can inspect and operators can support.

## Acceptance Scenarios

The MVP should be considered successful if the following scenarios work end to end.

A trusted low-value transfer can auto-execute within policy limits.

A trusted high-value transfer is routed to approval or cooldown instead of silent execution.

An unknown address is held or blocked rather than treated as safe by default.

A sanctioned address is blocked before execution and the operator can
see which list triggered the block.

A scam- or phishing-labelled address is challenged and routed to manual
review instead of silent execution.

Conflicted evidence prevents auto-execution until the trust state is resolved.

A swap outside allowed slippage or policy bounds is blocked.

Revoked delegation stops execution immediately.

An operator can approve or reject a queued action from Telegram and the
audit trail records that the action came from the bot surface.

Any completed or blocked action can be replayed from audit data and explained to an operator.

## Non-Functional Requirements

The platform must never require the platform operator to hold end-user private keys.

No execution should occur without policy evaluation, simulation, and audit capture.

Operators must have realtime visibility into queued, approved, executed, and blocked actions.

The system must degrade safely when quote providers, simulation providers, or chain integrations fail. Failure should widen caution, not widen autonomy.

## Conclusion

`Bank v0.1` should begin as a narrow, credible wedge: a safe non-custodial AI treasury runtime for power users operating with stablecoins on-chain.

The architecture should reflect that purpose. Phoenix should own the control plane. Postgres should hold the truth. Oban and PubSub should coordinate operational flow. TypeScript should handle chain-specific execution adapters. Solidity should remain minimal and focused on enforceable on-chain permissions.

The MVP does not need to solve all of crypto finance. It needs to prove one thing well: AI agents can become operationally useful around money when policy, trust, simulation, audit, and execution are designed as one system.
