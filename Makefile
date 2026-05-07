# Common ops for the Bank control plane.
# Run `make help` for the full list.

.PHONY: help setup test precommit adapter-check run release image staging-up staging-down staging-logs migrate seed hooks-install secret-guard

help:
	@echo "Bank — common make targets"
	@echo ""
	@echo "  setup         Install deps, set up DB and assets."
	@echo "  test          Run the test suite."
	@echo "  precommit     Warn-as-error compile, unused deps check, format, test."
	@echo "  adapter-check Typecheck and test the TypeScript chain adapter."
	@echo "  run           Start Phoenix on :4000 (dev)."
	@echo "  release       Build a mix release into _build/prod/rel/bank."
	@echo "  image         Build the Docker image tagged bank:staging."
	@echo "  staging-up    Bring up the local staging-like stack."
	@echo "  staging-down  Stop the local staging stack (keeps volumes)."
	@echo "  staging-logs  Follow phoenix logs from the local stack."
	@echo "  migrate       Run ecto migrations against the current env."
	@echo "  seed          Run priv/repo/seeds.exs."
	@echo "  hooks-install Install the local pre-commit secret-guard hook."
	@echo "  secret-guard  Run the secret-guard against currently staged files."

setup:
	mix setup

test:
	mix test

precommit:
	mix precommit

adapter-check:
	cd chain_adapter && npm ci && npm run typecheck && npm run typecheck:scripts && npm test

run:
	mix phx.server

release:
	MIX_ENV=prod mix deps.get --only prod
	MIX_ENV=prod mix compile
	MIX_ENV=prod mix assets.deploy
	MIX_ENV=prod mix release --overwrite

image:
	docker build -t bank:staging .

staging-up:
	docker compose --env-file .env.staging up --build -d

staging-down:
	docker compose --env-file .env.staging down

staging-logs:
	docker compose --env-file .env.staging logs -f phoenix

migrate:
	mix ecto.migrate

seed:
	mix run priv/repo/seeds.exs

# Install the pre-commit secret-guard hook into the local clone. Idempotent.
# See docs/runbooks/secrets-rotation.md (audit finding C1) for what the hook
# blocks and how to bypass it for audited test fixtures.
hooks-install:
	@mkdir -p .git/hooks
	@ln -sf ../../scripts/secret-guard.sh .git/hooks/pre-commit
	@chmod +x scripts/secret-guard.sh
	@echo "secret-guard installed at .git/hooks/pre-commit"

# Run the guard against staged changes without committing. Useful for CI or
# `git stash; make secret-guard; git stash pop` style audits.
secret-guard:
	@./scripts/secret-guard.sh
