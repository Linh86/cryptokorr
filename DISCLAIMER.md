# Disclaimer

**Please read this disclaimer carefully before using, evaluating, or
relying on CryptoKorr in any way.**

CryptoKorr is provided on an "AS IS" and "AS AVAILABLE" basis, without
warranties or conditions of any kind, either express or implied. By
using this software you accept the limitations described below.

## 1. Alpha software

CryptoKorr is **pre-release, private-alpha software**. The codebase is
under active development. Interfaces, schemas, data models, decision
semantics, execution paths, audit shapes, and runtime guarantees may
change without notice and without backward compatibility.

CryptoKorr has not undergone a formal external security audit. There
is no bug bounty program, no insurance, no production support process,
and no commitment to availability, response times, or service levels.

## 2. Not a bank, custodian, or financial institution

Despite its codename, **CryptoKorr is not a bank**. It does not
provide banking, deposit-taking, custody, money-transmission,
brokerage, exchange, payment-processing, or any other regulated
financial service.

CryptoKorr is non-custodial by design. The user retains control of
their own externally owned account and smart account at all times.
CryptoKorr never takes custody of user funds or private keys. The
software operates only through scoped, revocable smart-account
permissions that the user installs and that the user can revoke.

## 3. Not investment, financial, legal, or tax advice

Nothing produced by CryptoKorr — including but not limited to risk
explanations, policy evaluations, trust assessments, simulation
reports, route comparisons, quote previews, decision envelopes,
notifications, or any other output — constitutes investment advice,
financial advice, legal advice, accounting advice, tax advice, or any
form of professional recommendation.

The software does not assess whether any action is suitable for any
particular user, jurisdiction, or set of circumstances. Users are
responsible for obtaining independent professional advice before
making any financial decision and for ensuring that their use of the
software complies with all laws and regulations applicable to them.

## 4. Crypto-asset and on-chain risks

Use of CryptoKorr involves interaction with blockchains, smart
contracts, decentralized finance protocols, and digital assets. These
technologies carry significant and well-documented risks, including
but not limited to:

- total or partial loss of funds due to bugs, exploits, oracle
  failures, governance changes, slashing, liquidations, or other
  protocol-level events;
- adverse market conditions, illiquidity, slippage, frontrunning,
  sandwich attacks, MEV, and other execution risks;
- bridge failures, message-relayer failures, finality reversion, chain
  reorganizations, and cross-chain settlement risk;
- counterparty risk in any external venue, router, bridge, lending
  market, vault, or relay;
- regulatory action that may render assets, protocols, or jurisdictions
  unavailable, frozen, or unlawful;
- irreversible transactions: once broadcast and confirmed, on-chain
  actions generally cannot be undone, even if executed in error.

CryptoKorr's policy, trust, screening, simulation, and decision layers
are designed to reduce, but cannot eliminate, these risks. Users
assume all risk of using the software and of any on-chain action that
results from their use of it.

## 5. Scope limitations of the current release

At the time of this notice, CryptoKorr's live execution capabilities
are deliberately narrow. They include test-network execution paths on
Base Sepolia for selected stablecoin transfers, selected exact-input
swaps via 0x, and allowlisted deposits into a single risk-explained
ERC-4626 vault. Other capabilities — including but not limited to
mainnet usage, cross-chain bridging, additional routing providers,
arbitrary token lists, autonomous yield-vault withdrawals, borrowing,
leverage, looping, agent-supplied calldata, multi-account routing,
sponsored gas, and on-chain anchoring of audit hashes — are not
supported, are scaffolded with fail-closed behavior, or are explicitly
post-MVP.

Live behavior depends on the availability and correctness of third-
party services (RPC nodes, bundlers, paymasters, indexers, quote
providers, screening feeds, bridges, and vault protocols). CryptoKorr
makes no warranty regarding the availability, accuracy, latency,
completeness, or honesty of any third-party service.

## 6. Use of third parties

CryptoKorr integrates with and references third-party protocols,
services, and software, including those listed in the NOTICE file at
the root of this repository. Such references are for interoperability
purposes only and do not imply any endorsement, affiliation, or
sponsorship. The user is responsible for reviewing and complying with
the terms of service, licenses, and acceptable-use policies of any
third party with which they interact through CryptoKorr.

## 7. No warranty; limitation of liability

The CryptoKorr software is licensed under the Apache License, Version
2.0. As stated in Sections 7 and 8 of that license:

> Licensor provides the Work (and each Contributor provides its
> Contributions) on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS
> OF ANY KIND, either express or implied, including, without
> limitation, any warranties or conditions of TITLE, NON-INFRINGEMENT,
> MERCHANTABILITY, or FITNESS FOR A PARTICULAR PURPOSE.

> In no event and under no legal theory […] shall any Contributor be
> liable to You for damages […] arising as a result of this License
> or out of the use or inability to use the Work […].

Without limiting the foregoing, the Licensor and contributors shall
not be liable for any loss of funds, loss of profits, loss of data,
loss of business, regulatory penalties, or any direct, indirect,
incidental, special, exemplary, or consequential damages arising out
of or in connection with the use of CryptoKorr.

## 8. Jurisdiction and eligibility

The user is responsible for determining whether their use of
CryptoKorr is lawful in their jurisdiction and for any jurisdiction
into which their use of the software touches. The user represents and
warrants that they are not located in, organized under the laws of,
ordinarily resident in, or otherwise subject to sanctions by any
jurisdiction subject to comprehensive sanctions by the United Nations,
the European Union, the United Kingdom, the United States, or any
other competent authority, and that they are not a sanctioned person
under any such program.

## 9. Changes to this disclaimer

This disclaimer may be updated at any time without notice. The
version in the repository at the time of use governs that use.

## 10. Contact

Questions about this disclaimer may be directed to
[security@linh.cz](mailto:security@linh.cz).
