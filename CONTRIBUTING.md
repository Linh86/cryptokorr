# Contributing to CryptoKorr

Thank you for your interest in CryptoKorr. Before contributing, please
read this document in full. It explains what kinds of contributions are
useful at this stage, how to submit them, and what legal terms apply
when you do.

## Project status

CryptoKorr is **pre-release, private-alpha software** maintained by a
small team. The codebase is published under the Apache License 2.0
primarily for transparency, audit, and review, **not** to grow a large
community-driven feature pipeline.

That means we welcome:

- Security reports — see [SECURITY.md](./SECURITY.md). These take
  priority over everything else.
- Bug reports with clear reproduction steps.
- Documentation fixes (typos, broken links, clarifications, examples).
- Small, focused improvements where the maintainers have explicitly
  agreed scope in a tracking issue first.

We are usually **not** in a position to accept:

- Large refactors, sweeping renames, or stylistic rewrites.
- New chains, new venues, new asset types, new intent kinds, new
  decision pathways, or new operator surfaces submitted without a
  prior design discussion.
- Changes to security-sensitive areas — policy evaluation, trust and
  evidence handling, wallet screening, simulation, decision envelopes,
  approval queue, execution-plan creation, audit, delegation grant
  and revoke flows, RBAC, API-key authentication, or pause and revoke
  controls — submitted without explicit maintainer sponsorship.
- Pull requests opened without a corresponding issue.

If you are not sure where your idea falls, please open an issue first.

## How to file an issue

1. Search existing issues to avoid duplicates.
2. For security issues, **do not file a public issue**. Follow
   [SECURITY.md](./SECURITY.md) and email
   [security@linh.cz](mailto:security@linh.cz) instead.
3. For bugs, please include:
   - what you did,
   - what you expected to happen,
   - what actually happened,
   - environment details (commit, OS, runtime versions),
   - logs or stack traces with secrets and addresses redacted.
4. For feature ideas or design proposals, please describe the problem
   you are trying to solve before proposing a specific solution. A
   maintainer will respond on whether and how the idea fits the
   roadmap.

## How to submit a pull request

1. **Open an issue first** describing what you intend to change and
   why. Wait for a maintainer to confirm that the change is in scope
   before you start coding. This protects your time as much as ours.
2. Fork the repository and create a topic branch off `main`.
3. Keep pull requests focused and as small as reasonably possible.
   Unrelated changes should be split into separate pull requests.
4. Follow the conventions already present in the code:
   - Match existing module structure and naming patterns.
   - Update or add tests for behavior changes.
   - Run the project's precommit gate locally before pushing.
   - Update documentation, runbooks, and OpenAPI artifacts when the
     change touches them.
5. Do not introduce new dependencies without explicit approval.
6. Do not commit secrets, real private keys, mainnet addresses tied to
   real funds, screenshots that reveal them, or any other sensitive
   data. The repository's secret-hygiene tests will reject many of
   these, but please do not rely on automation here.
7. Write clear commit messages. The body should explain *why*, not
   just *what*.
8. Sign off every commit — see the next section.

The maintainers may request changes, ask you to split the pull
request, or, where the change conflicts with the project's roadmap or
security posture, decline the pull request. We try to be respectful
of your time; please be respectful of ours.

## Developer Certificate of Origin (DCO)

CryptoKorr uses the [Developer Certificate of Origin][dco-link]
(DCO) version 1.1. The DCO is a lightweight way for contributors to
certify that they wrote, or otherwise have the right to submit, the
code they are contributing. We do **not** use a separate Contributor
License Agreement (CLA).

By contributing to this project — that is, by submitting a pull
request, a patch, a code suggestion, or any other content for
inclusion in the work — you certify the following on your own behalf:

> Developer Certificate of Origin
> Version 1.1
>
> By making a contribution to this project, I certify that:
>
> (a) The contribution was created in whole or in part by me and I
>     have the right to submit it under the open source license
>     indicated in the file; or
>
> (b) The contribution is based upon previous work that, to the best
>     of my knowledge, is covered under an appropriate open source
>     license and I have the right under that license to submit that
>     work with modifications, whether created in whole or in part by
>     me, under the same open source license (unless I am permitted
>     to submit under a different license), as indicated in the file;
>     or
>
> (c) The contribution was provided directly to me by some other
>     person who certified (a), (b), or (c) and I have not modified
>     it.
>
> (d) I understand and agree that this project and the contribution
>     are public and that a record of the contribution (including all
>     personal information I submit with it, including my sign-off)
>     is maintained indefinitely and may be redistributed consistent
>     with this project or the open source license(s) involved.

You certify the DCO for each contribution by adding a `Signed-off-by`
trailer to every commit:

```
Signed-off-by: Your Real Name <your.email@example.com>
```

Git can add this for you automatically with `git commit -s`. The name
must be your real legal name; pseudonymous sign-offs are not accepted.
The email must be one you control.

Contributions without a valid DCO sign-off on every commit cannot be
merged. You may amend a pull request to add missing sign-offs using
`git commit --amend -s` and `git rebase --signoff`.

## License of contributions

By submitting a contribution to CryptoKorr you agree that your
contribution will be licensed under the Apache License, Version 2.0,
the same license that covers the rest of the project. See
[LICENSE](./LICENSE) for the full text.

## Code of conduct

We expect everyone interacting with this project — in issues, pull
requests, commit messages, code review, and any other project space —
to be respectful and constructive. In short:

- Be kind. Disagree with ideas, not people.
- Assume good faith.
- Keep discussion focused on the technical and product substance.
- No harassment, personal attacks, or discriminatory language of any
  kind.

Maintainers may, at their discretion, edit, hide, or remove
contributions that do not meet these expectations, and may block users
who repeatedly violate them.

## Contact

For non-security questions about contributing, please open a
discussion or an issue in the repository.

For security reports, please follow [SECURITY.md](./SECURITY.md) and
email [security@linh.cz](mailto:security@linh.cz).

[dco-link]: https://developercertificate.org/
