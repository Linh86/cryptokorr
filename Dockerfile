# syntax=docker/dockerfile:1.6

# Multi-stage release build for the Bank Phoenix control plane.
#
# Build:   docker build -t bank:staging .
# Run:     docker run --rm -p 4000:4000 \
#            -e DATABASE_URL=... \
#            -e SECRET_KEY_BASE=... \
#            -e ADAPTER_BASE_URL=... \
#            -e ADAPTER_AUTH_SECRET=... \
#            -e PHX_HOST=... \
#            -e PHX_SERVER=true \
#            bank:staging

ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20241016-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# --- Build stage -------------------------------------------------------------

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y build-essential git curl \
  && apt-get clean \
  && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
COPY assets assets

RUN mix assets.deploy
RUN mix compile

COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# --- Runtime stage -----------------------------------------------------------

FROM ${RUNNER_IMAGE} AS runtime

RUN apt-get update -y \
  && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean \
  && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

WORKDIR /app

RUN chown nobody /app

ENV MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

COPY --from=builder --chown=nobody:root /app/_build/prod/rel/bank ./

USER nobody

EXPOSE 4000

CMD ["/app/bin/server"]
