# syntax=docker/dockerfile:1
#
# Multi-stage build for the standalone Bier server.
#   docker build -t bier .
#   docker run --rm -e PGRST_DB_URI=postgresql://user:pass@host:5432/db \
#                    -e PGRST_DB_SCHEMAS=api -e PGRST_DB_ANON_ROLE=web_anon \
#                    -p 3000:3000 bier
#
# The image runs `bin/bier start`, which boots ONE Bier instance from PGRST_*
# env vars (BIER_STANDALONE=1 is baked in). See README "Running standalone".

ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.5.0.1-debian-bookworm-20260518-slim
ARG RUNTIME_IMAGE=debian:bookworm-slim

# ---- build stage ----
FROM ${ELIXIR_IMAGE} AS build

RUN apt-get update -y \
    && apt-get install -y build-essential git \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Fetch & compile prod dependencies (cached unless mix.exs/mix.lock change).
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Compile-time config and source, then assemble the release.
COPY config config
COPY lib lib
RUN mix compile
RUN mix release

# ---- runtime stage ----
FROM ${RUNTIME_IMAGE} AS app

# The release bundles ERTS, so only the C libraries it links against are needed.
RUN apt-get update -y \
    && apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Elixir/Erlang need a UTF-8 locale.
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
COPY --from=build --chown=nobody:root /app/_build/prod/rel/bier ./
USER nobody

# Run as a standalone server configured entirely via PGRST_* env vars.
ENV BIER_STANDALONE=1
ENV PGRST_SERVER_PORT=3000
EXPOSE 3000

ENTRYPOINT ["/app/bin/bier"]
CMD ["start"]
