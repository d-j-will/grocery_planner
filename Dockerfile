# Find eligible builder and runner images on Docker Hub. We use Ubuntu/Debian instead of Alpine to avoid DNS resolution issues in production.
#
# https://hub.docker.com/r/hexpm/elixir/tags?page=1&name=ubuntu
# https://hub.docker.com/_/ubuntu?tab=tags
#
#
# This file is based on these images:
#
#   - https://hub.docker.com/r/hexpm/elixir/tags - for the build image
#   - https://hub.docker.com/_/debian?tab=tags&page=1&name=bullseye-20230612-slim - for the release image
#   - https://pkgs.org/ - resource for finding needed packages
#   - Ex: hexpm/elixir:1.15.7-erlang-26.1.2-debian-bullseye-20230612-slim
#
# SINGLE SOURCE OF TRUTH for the language versions is /.tool-versions (mise).
# The deploy workflow extracts elixir/erlang from it and passes --build-arg, so
# CI/prod builds always match local dev + CI's setup-beam. These defaults are the
# fallback for a plain `docker build` and MUST equal .tool-versions.
# (Building on an older Elixir than CI silently breaks deps using newer stdlib —
# e.g. langchain needs get_in/1, Elixir 1.17+; that's why this must not drift.)
# DEBIAN_VERSION is a base-image detail (not a language version) so it lives here,
# not in .tool-versions. hexpm ships this combo on bookworm+ only.
ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5.0.3
ARG DEBIAN_VERSION=bookworm-20260623-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} as builder

# install build dependencies
RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

# prepare build dir
WORKDIR /app

# install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# set build ENV
ENV MIX_ENV="prod"

# install mix dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# copy compile-time config files before we compile dependencies
# to ensure any relevant config change will trigger the dependencies
# to be re-compiled.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

COPY priv priv

COPY lib lib
COPY assets assets

# Compile the application first (to generate colocated hooks)
RUN mix compile

# compile assets
RUN mix assets.deploy

# Changes to config/runtime.exs don't require recompiling the code
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# start a new build stage so that the final image will only contain
# the compiled release and other runtime necessities
FROM ${RUNNER_IMAGE}

# curl is required by the compose healthcheck (GET /health_check) — see
# docker-compose.prod.yml. Keep it in the runtime deps, not just the builder.
RUN apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales curl \
  && apt-get clean && rm -f /var/lib/apt/lists/*_*

# Set the locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# set runner ENV
ENV MIX_ENV="prod"

# Only copy the final release from the build stage
COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/grocery_planner ./

USER nobody

CMD ["/app/bin/grocery_planner", "start"]
