# syntax=docker/dockerfile:1

############################################################
# Builder — compile CLIProxyAPI from the official source
############################################################
FROM golang:1.26-bookworm AS builder

# Pin to an official release tag. Override at build time:
#   docker build --build-arg CLIPROXY_VERSION=v7.2.147 ...
ARG CLIPROXY_VERSION=v7.2.146

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN git clone --depth 1 --branch "${CLIPROXY_VERSION}" \
    https://github.com/router-for-me/CLIProxyAPI.git .

ARG BUILD_DATE=unknown

# Mirrors the upstream build: CGO enabled, stripped binary, version metadata
# injected via ldflags.
RUN CGO_ENABLED=1 GOOS=linux go build -buildvcs=false \
    -ldflags="-s -w \
      -X 'main.Version=${CLIPROXY_VERSION}' \
      -X 'main.Commit=$(git rev-parse --short HEAD)' \
      -X 'main.BuildDate=${BUILD_DATE}'" \
    -o /out/CLIProxyAPI ./cmd/server/

############################################################
# Runtime — slim image, non-root, no build tools
############################################################
FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata curl gettext-base \
    && rm -rf /var/lib/apt/lists/*

# UTC by default; override with -e TZ=... at runtime.
ENV TZ=UTC

# Dedicated non-root user with a stable UID/GID for volume ownership.
RUN groupadd --gid 10001 cliproxy \
    && useradd --uid 10001 --gid cliproxy --create-home --shell /usr/sbin/nologin cliproxy

WORKDIR /CLIProxyAPI

COPY --from=builder /out/CLIProxyAPI ./CLIProxyAPI
COPY --from=builder /src/config.example.yaml ./config.example.yaml
COPY config.template.yaml ./config.template.yaml
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh

# config/ holds the rendered config.yaml, auths/ the OAuth tokens, logs/ the
# rotating log files. All three are volume mount points.
RUN mkdir -p config auths logs \
    && chmod +x /usr/local/bin/docker-entrypoint.sh \
    && chown -R cliproxy:cliproxy /CLIProxyAPI

USER cliproxy

# Main API port. OAuth login callback ports (8085, 1455, 54545, 51121, 11451)
# are only needed during interactive provider login — publish them ad hoc.
EXPOSE 8317

VOLUME ["/CLIProxyAPI/config", "/CLIProxyAPI/auths", "/CLIProxyAPI/logs"]

# The server has no dedicated health route; any HTTP response on the listen
# port means the process is up (connection refused fails the check).
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -s -o /dev/null "http://127.0.0.1:${CLIPROXY_PORT:-8317}/" || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["--config", "/CLIProxyAPI/config/config.yaml"]
