ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.2.1
ARG DEBIAN_VERSION=bookworm-20241016-slim

# Build stage
FROM hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION} AS build

ENV MIX_ENV=prod

WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

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
RUN mix compile
RUN mix release

# Runtime stage
FROM debian:${DEBIAN_VERSION}

ARG TARGETARCH

ENV LANG=C.UTF-8
ENV UNEX_PORT=8005
ENV UNEX_DATA=/app/data

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses5 locales wget ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Install UCM
RUN case "${TARGETARCH}" in \
      arm64) UCM_ARCH="arm64" ;; \
      amd64) UCM_ARCH="x64" ;; \
      *) echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    wget -q "https://github.com/unisonweb/unison/releases/download/release%2F1.1.1/ucm-linux-${UCM_ARCH}.tar.gz" -O /tmp/ucm.tar.gz && \
    tar -xzf /tmp/ucm.tar.gz -C /usr/local/bin && \
    rm /tmp/ucm.tar.gz && \
    ucm version

# Create app user
RUN groupadd --system unex && useradd --system unex -g unex

# Copy release and healthcheck
COPY --from=build /app/_build/prod/rel/unex /app
COPY healthcheck.sh /app/healthcheck.sh
RUN chmod +x /app/healthcheck.sh

# Create data directory
RUN mkdir -p /app/data && chown unex:unex /app/data

USER unex
WORKDIR /app

ENTRYPOINT ["/app/bin/unex"]
CMD ["start"]
