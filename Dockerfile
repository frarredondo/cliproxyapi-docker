# syntax=docker/dockerfile:1

############################################################
# Builder — compile CLIProxyAPI from the official source
############################################################
FROM golang:1.26-bookworm AS builder

# The exact upstream tag and commit to build. Both come from cliproxy.lock via
# the Makefile and deliberately have no defaults — a default here would only
# ever mean "silently build the wrong version".
ARG CLIPROXY_VERSION
ARG CLIPROXY_COMMIT

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# The commit SHA is checked here, in the same layer as the clone, for two
# reasons: it catches upstream moving a tag, and because the SHA appears in
# this RUN's text it joins the layer cache key — so a moved tag actually
# rebuilds instead of silently reusing the old source.
RUN test -n "${CLIPROXY_VERSION}" || { echo "FATAL: build-arg CLIPROXY_VERSION is required — build with 'make build'" >&2; exit 1; }; \
    test -n "${CLIPROXY_COMMIT}"  || { echo "FATAL: build-arg CLIPROXY_COMMIT is required — build with 'make build'" >&2; exit 1; }; \
    git clone --depth 1 --branch "${CLIPROXY_VERSION}" \
      https://github.com/router-for-me/CLIProxyAPI.git . && \
    actual="$(git rev-parse HEAD)" && \
    if [ "${actual}" != "${CLIPROXY_COMMIT}" ]; then \
      echo "FATAL: tag ${CLIPROXY_VERSION} now resolves to ${actual}," >&2; \
      echo "       but cliproxy.lock expects ${CLIPROXY_COMMIT}. Upstream moved the tag." >&2; \
      echo "       Run 'make update' and review the lockfile diff before building." >&2; \
      exit 1; \
    fi

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

# Re-declared: ARGs are per-stage, so the builder's copies are not visible
# here. Kept last so this cheap layer never invalidates the Go compile.
ARG CLIPROXY_VERSION
ARG CLIPROXY_COMMIT
LABEL org.opencontainers.image.version="${CLIPROXY_VERSION}" \
      org.opencontainers.image.revision="${CLIPROXY_COMMIT}" \
      org.opencontainers.image.source="https://github.com/router-for-me/CLIProxyAPI"

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["--config", "/CLIProxyAPI/config/config.yaml"]
