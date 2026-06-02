# Publishing — SDK and MCP packages

> **Do not publish without explicit operator authorization.** This
> document captures the *commands*; running them ships an immutable
> artifact to PyPI / npm. The repo's CI does **not** publish; a human
> with credentials does.

This guide covers all three publish targets:

- `cryptokorr` (Python SDK) — PyPI.
- `@cryptokorr/sdk` (TypeScript SDK) — npm.
- `cryptokorr-mcp` (stdio MCP server) — PyPI.

If you're a developer who just wants to install one of these locally,
skip to the package READMEs:
[`sdks/python/README.md`](python/README.md),
[`sdks/typescript/README.md`](typescript/README.md),
[`sdks/mcp/README.md`](mcp/README.md).

---

## Pre-publish checklist (every package, every release)

1. **CI is green on `main` for the commit you're shipping.** No
   exceptions — there is no "fix it post-publish" path on PyPI/npm.
2. **The package's `CHANGELOG.md` has an entry for the version.** Move
   `[Unreleased]` to a versioned section with today's date.
3. **The version in the package manifest matches the CHANGELOG.**
   `pyproject.toml`'s `version` and `package.json`'s `version` are
   the source of truth; CHANGELOG mirrors them.
4. **Local dry-run succeeds.** See "Per-package commands" below.
5. **The README's install snippet works for the version you're
   shipping.** Re-paste it into a fresh shell and confirm.
6. **Secrets are out of every artifact.** No `.env`, no test keys, no
   tokens in `dist/` or `build/`. PyPI and npm cache forever; even a
   yanked release is publicly visible.
7. **License declaration matches reality.** See "License resolution"
   below — there is currently a discrepancy across the three packages
   that must be resolved before any publish.

If any of those is `no`, stop. Don't publish.

---

## Per-package build / dry-run commands

These are **safe** to run locally — they produce artifacts under
`dist/` (or `build/` for hatchling) but never push.

### `cryptokorr` (Python SDK) — setuptools

```bash
cd sdks/python
python -m venv .venv
source .venv/bin/activate
pip install --upgrade build twine

# Clean any prior artefacts
rm -rf build dist *.egg-info

# Build sdist + wheel
python -m build

# Inspect what's inside
ls -la dist/
unzip -l dist/cryptokorr-*.whl | head -40

# Validate metadata against PyPI's rules without uploading
python -m twine check dist/*
```

### `@cryptokorr/sdk` (TypeScript SDK) — tsc + npm pack

```bash
cd sdks/typescript
npm ci
npm run typecheck
npm test
npm run build           # populates dist/

# Inspect the tarball that 'npm publish' would upload
npm pack --dry-run

# Or write the tarball to disk and inspect
npm pack
tar -tzf cryptokorr-sdk-*.tgz | head -40
```

The `prepublishOnly` script chains `typecheck → test → build`, so
`npm publish` (or `npm publish --dry-run`) will refuse to ship if any
step fails. Do not bypass it.

### `cryptokorr-mcp` (stdio MCP server) — hatchling

```bash
cd sdks/mcp
python -m venv .venv
source .venv/bin/activate
pip install --upgrade build twine

rm -rf build dist *.egg-info

python -m build

ls -la dist/
unzip -l dist/cryptokorr_mcp-*.whl | head -40

python -m twine check dist/*

# Smoke the console-script entry from the freshly built wheel
pip install --force-reinstall dist/cryptokorr_mcp-*.whl
CRYPTOKORR_API_KEY="cb_test_doesnotexist0000" cryptokorr-mcp <<< '{"jsonrpc":"2.0","id":1,"method":"initialize"}'
# Expect a single JSON-RPC response with serverInfo on stdout.
```

---

## Versioning policy

- **Semver.** All three packages follow
  [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).
- **API contract drives major.** A breaking change to `/v1/*`
  (renamed/removed endpoint, removed field, narrowed enum) is a
  major-version bump on every package that touches it. The OpenAPI
  artifact is the source of truth.
- **MCP tool surface drives MCP major.** Renaming or removing a tool,
  or shrinking a tool's input schema, is a major-version bump on
  `cryptokorr-mcp`.
- **Independent minor/patch.** Each package can ship a minor or patch
  release independently — they don't have to march together. Track
  drift in this doc if it grows beyond two minor versions across
  packages.
- **Pre-1.0.** All three packages start at `0.1.0`. Per semver, minor
  bumps may be breaking until `1.0.0`. We treat that latitude
  conservatively: every breaking change still gets called out at the
  top of the CHANGELOG entry.

---

## Publish commands (do not run without explicit authorization)

> **Stop here unless an authorized operator has told you to publish a
> specific version.** The commands below are documentation, not a
> runbook step. CI does not run them.

Authentication is via env-var-supplied tokens. **Never** paste a token
on a CLI flag, into shell history, or into a commit. Use a token
manager (`pass`, 1Password CLI, AWS Secrets Manager, etc.) that
exports into the shell session and clears on exit.

### `cryptokorr` → PyPI

```bash
cd sdks/python

# 0. Confirm CI is green and the version in pyproject.toml is what you
#    expect to ship.

# 1. Authenticate (token from PyPI account settings; scope to project).
export TWINE_USERNAME="__token__"
export TWINE_PASSWORD="pypi-..."   # supplied out-of-band; do not commit.

# 2. Build.
rm -rf build dist *.egg-info
python -m build

# 3. Optional: upload to TestPyPI first.
python -m twine upload --repository testpypi dist/*

# 4. Live upload.
python -m twine upload dist/*

# 5. Tag and push.
git tag cryptokorr-py-<version>
git push origin cryptokorr-py-<version>
```

### `@cryptokorr/sdk` → npm

The package currently has `"private": true` set in `package.json`
specifically so an accidental `npm publish` refuses. Removing that
flag is part of the deliberate publish step — and must be removed in
the same commit that lands the new version.

```bash
cd sdks/typescript

# 0. Confirm CI is green and version in package.json is correct.

# 1. Authenticate (token from npm account settings; scope: read+write
#    on @cryptokorr).
npm login                  # or pre-set ~/.npmrc with "//registry.npmjs.org/:_authToken=..."

# 2. Drop the private flag (do this in the version-bump commit).
#    "private": false      OR delete the key.
#    "publishConfig": { "access": "public" }   ← also flip to public.

# 3. Optional: dry-run.
npm publish --dry-run

# 4. Live publish (prepublishOnly chains typecheck → test → build).
npm publish

# 5. Tag and push.
git tag cryptokorr-ts-<version>
git push origin cryptokorr-ts-<version>
```

### `cryptokorr-mcp` → PyPI

```bash
cd sdks/mcp

# 0. Confirm CI is green and version in pyproject.toml is correct.

# 1. Authenticate (separate PyPI token, scope: cryptokorr-mcp project).
export TWINE_USERNAME="__token__"
export TWINE_PASSWORD="pypi-..."

# 2. Build.
rm -rf build dist *.egg-info
python -m build

# 3. Optional: TestPyPI.
python -m twine upload --repository testpypi dist/*

# 4. Live upload.
python -m twine upload dist/*

# 5. Tag and push.
git tag cryptokorr-mcp-<version>
git push origin cryptokorr-mcp-<version>
```

---

## License resolution (publish-blocker)

The three packages currently declare different licenses, and there is
no top-level `LICENSE` file in the repo. **Resolve before any
publish.** PyPI and npm both surface license metadata prominently;
shipping inconsistent license claims confuses downstream consumers.

| Package           | Manifest license claim         | LICENSE file? |
| ----------------- | ------------------------------ | ------------- |
| `cryptokorr`      | `Apache-2.0` in `pyproject.toml` | ✗            |
| `@cryptokorr/sdk` | `MIT` in `package.json`          | ✗            |
| `cryptokorr-mcp`  | (not declared)                  | ✗            |

Recommended path:

1. Pick one license for everything (Apache-2.0 and MIT are both
   permissive; Apache-2.0 includes a patent grant).
2. Add a top-level `LICENSE` file with the full SPDX text.
3. Mirror the same SPDX identifier into every package manifest.
4. Land that as a single PR before any publish.

---

## MCP community-directory submission checklist

After `cryptokorr-mcp` is on PyPI and the README install snippet
works, submit to the MCP community directory at
<https://github.com/modelcontextprotocol/servers>.

Required for the directory entry:

- [ ] Package is installable from PyPI: `pip install cryptokorr-mcp`
      runs from a clean venv and exposes the `cryptokorr-mcp` console
      script.
- [ ] README documents the Claude Desktop and Cursor JSON config
      snippets verbatim. (Already true — see
      [`sdks/mcp/README.md`](mcp/README.md).)
- [ ] README documents the `CRYPTOKORR_READONLY=true` posture so
      directory readers can recommend the safe-by-default config to
      end users.
- [ ] Tool list (with descriptions) is documented at a stable URL.
      Use the section in
      [`docs/api/mcp-tools.md`](../docs/api/mcp-tools.md).
- [ ] Submission PR title: `[New Server] cryptokorr-mcp — non-custodial
      treasury intents and decisions`.
- [ ] Category: `Finance` or `DeFi` (whichever the directory uses
      this quarter).

The submission is a docs-only PR to the directory repo. CryptoKorr's
publish process and the directory submission are independent — list
in the directory only after `cryptokorr-mcp` is live on PyPI.

---

## After publishing

1. Smoke-test the live install in a clean environment:
   ```bash
   python -m venv /tmp/cb-smoke && source /tmp/cb-smoke/bin/activate
   pip install cryptokorr        # for the SDK
   pip install cryptokorr-mcp    # for the MCP server
   # In another shell, an empty Node project:
   npm install @cryptokorr/sdk
   ```
2. Open a release note under [`docs/`](../docs/) (or a GitHub Release)
   linking to the package CHANGELOG entry.
3. Update the [`sdks/README.md`](README.md) install table if the
   recommended install command changed.
4. If a publish fails partway (e.g. PyPI rejects a duplicate version),
   bump the patch version, regenerate the CHANGELOG entry, rebuild,
   and retry. **Do not reuse a version number** — both PyPI and npm
   reject re-uploads.

---

## What this guide is not

- It is **not** a CI publish workflow. We deliberately keep publish
  manual until we have a tag-driven release pipeline that gates on
  human approval.
- It is **not** a "first launch" runbook. The first publish should
  also include a release announcement, public docs link, and (for the
  MCP server) the community-directory submission. Those steps live
  outside this file.
- It is **not** authoritative on credentials. Treat any token leaked
  in a log, commit, or shared screenshot as compromised: rotate
  immediately.
