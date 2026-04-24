ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.3.4.10
ARG DEBIAN_VERSION=bookworm-20260406-slim
# UCM version pinned for both the build (compile Dispatcher.uc) and runtime
# (run.compiled Dispatcher.uc) stages — dispatcher bytecode is tied to a
# specific base library hash, so the two MUST match.
ARG UCM_VERSION=1.2.0

# Build stage
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

ARG TARGETARCH
ARG UCM_VERSION

ENV MIX_ENV=prod

WORKDIR /app

# Install build dependencies + UCM (needed to produce data/dispatcher.uc).
RUN apt-get update && \
    apt-get install -y --no-install-recommends git wget ca-certificates libstdc++6 libncurses5 && \
    rm -rf /var/lib/apt/lists/*

RUN case "${TARGETARCH}" in \
      arm64) UCM_ARCH="arm64" ;; \
      amd64) UCM_ARCH="x64" ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    wget -q "https://github.com/unisonweb/unison/releases/download/release%2F${UCM_VERSION}/ucm-linux-${UCM_ARCH}.tar.gz" -O /tmp/ucm.tar.gz && \
    mkdir -p /usr/local/lib/ucm && \
    tar -xzf /tmp/ucm.tar.gz -C /usr/local/lib/ucm && \
    ln -sf /usr/local/lib/ucm/ucm /usr/local/bin/ucm && \
    rm /tmp/ucm.tar.gz && \
    ucm version

# UCM needs a writable $HOME for its local caches during lib.install.
ENV HOME=/root

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Install dependencies
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Compile application
COPY config config
COPY lib lib
COPY rel rel
COPY unison unison
RUN mix compile
RUN mix release

# Produce the dispatcher's .uc bundle OUTSIDE the data dir — the runtime stage
# typically has /app/data mounted as a persistent volume, which would shadow
# anything we baked into it. Keep the bundle at /app/dispatcher.uc instead.
RUN mix unex.compile_dispatcher --out /app/dispatcher && test -s /app/dispatcher.uc

# Runtime stage
FROM debian:${DEBIAN_VERSION}

ARG TARGETARCH
ARG UCM_VERSION

ENV LANG=C.UTF-8
ENV UNEX_PORT=8005
ENV UNEX_DATA=/app/data
# Keep the dispatcher bundle outside of UNEX_DATA so host-mounted volumes
# on /app/data don't shadow the image-baked file.
ENV UNEX_DISPATCHER=/app/dispatcher.uc

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses5 locales wget ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install UCM — same version as the build stage used to produce dispatcher.uc.
RUN case "${TARGETARCH}" in \
      arm64) UCM_ARCH="arm64" ;; \
      amd64) UCM_ARCH="x64" ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    wget -q "https://github.com/unisonweb/unison/releases/download/release%2F${UCM_VERSION}/ucm-linux-${UCM_ARCH}.tar.gz" -O /tmp/ucm.tar.gz && \
    mkdir -p /usr/local/lib/ucm && \
    tar -xzf /tmp/ucm.tar.gz -C /usr/local/lib/ucm && \
    ln -sf /usr/local/lib/ucm/ucm /usr/local/bin/ucm && \
    rm /tmp/ucm.tar.gz && \
    ucm version

# Create app user with home directory (UCM needs writable $HOME for cache)
RUN groupadd --system unex && useradd --system unex -g unex -m

# Copy release, healthcheck, and the pre-built dispatcher bundle.
COPY --from=build /app/_build/prod/rel/unex /app
COPY --from=build --chown=unex:unex /app/dispatcher.uc /app/dispatcher.uc
COPY healthcheck.sh /app/healthcheck.sh
RUN chmod +x /app/healthcheck.sh

# Data dir — this is usually a mounted volume at runtime. Create it here so
# the path exists if no volume is mounted.
RUN mkdir -p /app/data && chown -R unex:unex /app/data

USER unex
WORKDIR /app

ENTRYPOINT ["/app/bin/unex"]
CMD ["start"]
