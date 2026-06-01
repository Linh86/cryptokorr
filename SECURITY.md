# Security Policy

CryptoKorr is software that sits between AI agents and on-chain funds.
Even though it is non-custodial — the user retains control of their own
externally owned account and smart account at all times — bugs in this
codebase could still result in loss of user funds, exposure of
sensitive operational data, or bypass of policy and approval gates.

We take security reports seriously and appreciate the work of the
security community in keeping this project safe.

## Reporting a vulnerability

**Please do not file public GitHub issues for security vulnerabilities,
do not discuss them in public chat, and do not post proof-of-concept
exploits or affected addresses on social media.**

Report suspected security issues privately by email to:

**[security@linh.cz](mailto:security@linh.cz)**

If you would like to encrypt your report, request a PGP key at the
same address before sending the report itself.

### What to include

A useful report typically includes:

- A clear description of the issue and its impact.
- The component affected (Phoenix control plane, TypeScript chain
  adapter, SDK, MCP server, smart-account integration, etc.) and, if
  possible, the commit, branch, or release version.
- Reproduction steps, proof-of-concept code, or test transactions on
  a test network. Please **do not** use real funds, mainnet, or
  third-party accounts to demonstrate the issue.
- Any preconditions (configuration, environment variables, role,
  workspace state, delegation state) required to trigger the issue.
- Your assessment of severity and any suggested mitigation.
- Whether you intend to disclose publicly, and on what timeline.

You may report anonymously. If you provide contact details, we will
acknowledge receipt and keep you informed during triage.

## Scope

Security reports are welcome on, but not limited to, the following
areas:

- The Phoenix control plane: policy evaluation, trust and evidence
  handling, wallet/address screening, simulation and quote handling,
  decision envelopes, approval queue, execution-plan creation, audit
  and replay, workspace and RBAC enforcement, API-key authentication,
  rate limits, idempotency, and pause/revoke flows.
- The TypeScript chain adapter: UserOperation assembly, signing,
  broadcasting, callback reporting, Kernel and ZeroDev permission
  install and revoke paths, swap and deposit calldata construction.
- Smart-account interactions: ERC-4337 and ERC-7579 flows, scoped
  delegation behavior, revoke posture, and any path that could
  unintentionally widen on-chain authority.
- SDKs, the MCP server, and operator surfaces (web console, Telegram,
  notifications) where they could leak secrets, bypass policy, expose
  cross-workspace data, or be coerced into performing actions outside
  their stated scope.
- Privilege escalation, authentication bypass, or session-fixation
  issues in any operator or agent surface.
- Cryptographic mistakes (signing, hashing, randomness, key handling)
  and replay-attack vectors.
- Prompt-injection or tool-misuse paths that could cause an AI agent
  using CryptoKorr to bypass policy, approval, or audit gates.

### Out of scope

The following are generally **not** in scope:

- Vulnerabilities in third-party protocols, services, or contracts
  that CryptoKorr only integrates with (for example, RPC providers,
  bundlers, paymasters, indexers, quote providers, screening feeds,
  bridges, routers, lending markets, and ERC-4626 vaults). Please
  report those to the responsible upstream project.
- Findings that depend on an attacker already controlling the user's
  externally owned account, private keys, browser session, or device.
- Best-practice suggestions without a demonstrated security impact
  (for example, missing security headers on a marketing page).
- Theoretical issues without a reproducible path to user-fund loss,
  data exposure, or policy bypass.
- Issues that only affect long-deprecated or unreleased code paths.
- Denial-of-service caused only by exhausting paid third-party
  quotas.

If you are not sure whether something is in scope, please err on the
side of reporting.

## Our response

Once a report is received, we aim to:

1. Acknowledge receipt within **3 business days**.
2. Provide an initial triage assessment within **10 business days**,
   including a preliminary severity rating and whether the issue is in
   scope.
3. Keep you informed of progress on a reasonable cadence while we
   investigate and prepare a fix.
4. Coordinate a disclosure timeline with you. We will not publicly
   disclose details of the issue or the reporter without consent.

CryptoKorr is alpha software maintained by a small team. Response and
remediation times depend on severity, reproducibility, and the
availability of maintainers. Please be patient; we will keep you in
the loop.

## Safe-harbor for good-faith research

We will not pursue or support legal action against researchers who:

- make a good-faith effort to comply with this policy;
- avoid privacy violations, destruction of data, and interruption or
  degradation of services beyond what is strictly necessary to
  demonstrate a vulnerability;
- use only test networks and test accounts when demonstrating an
  issue and do not target the funds, data, or accounts of any other
  user;
- give us reasonable time to investigate and remediate before any
  public disclosure;
- do not attempt to extract data beyond what is needed to demonstrate
  the vulnerability.

This safe-harbor commitment is limited to actions within the control
of the CryptoKorr project. It does not bind any third party, and it
does not authorize activity that would violate the law of any
jurisdiction applicable to the researcher or to CryptoKorr.

## Bounty

There is **no paid bug-bounty program** at this time. We are grateful
for responsible reports and will publicly credit reporters with their
consent once a fix is released.

## Operational security expectations for users

CryptoKorr cannot protect against compromise of the user's own
environment. Users are responsible for:

- securing their externally owned account, hardware wallet, browser,
  and operating system;
- keeping API keys, session tokens, and operator credentials
  confidential and rotating them after suspected exposure;
- reviewing the scope of any smart-account delegation before signing
  the install transaction, and revoking delegations they no longer
  use;
- treating CryptoKorr's policy, approval, and audit gates as defense
  in depth, not as a substitute for prudent on-chain behavior.

## Contact

Security reports and questions about this policy:
[security@linh.cz](mailto:security@linh.cz)
