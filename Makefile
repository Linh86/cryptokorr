# Common ops for the Bank control plane.
# Run `make help` for the full list.

.PHONY: help setup test precommit run release image staging-up staging-down staging-logs migrate seed

help:
	@echo "Bank — common make targets"
	@echo ""
	@echo "  setup         Install deps, set up DB and assets."
	@echo "  test          Run the test suite."
	@echo "  precommit     Warn-as-error compile, unused deps check, format, test."
	@echo "  run           Start Phoenix on :4000 (dev)."
	@echo "  release       Build a mix release into _build/prod/rel/bank."
	@echo "  image         Build the Docker image tagged bank:staging."
	@echo "  staging-up    Bring up the local staging-like stack."
	@echo "  staging-down  Stop the local staging stack (keeps volumes)."
	@echo "  staging-logs  Follow phoenix logs from the local stack."
	@echo "  migrate       Run ecto migrations against the current env."
	@echo "  seed          Run priv/repo/seeds.exs."

setup:
	mix setup

test:
	mix test

precommit:
	mix precommit

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
