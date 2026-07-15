#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/CLIProxyAPI/config/config.yaml"
TEMPLATE_FILE="/CLIProxyAPI/config.template.yaml"

# First start: render config.yaml from the template using CLIPROXY_* env vars.
# If a config already exists (user-provided or from a previous run), it is
# used as-is and the environment variables are ignored.
if [[ ! -f "${CONFIG_FILE}" ]]; then
    if [[ -z "${CLIPROXY_API_KEY:-}" ]]; then
        echo "ERROR: CLIPROXY_API_KEY is not set and no config file exists at ${CONFIG_FILE}." >&2
        echo "Generate one with:  openssl rand -hex 32" >&2
        echo "Then pass it via -e CLIPROXY_API_KEY=... or the compose .env file." >&2
        exit 1
    fi

    export CLIPROXY_HOST="${CLIPROXY_HOST:-}"
    export CLIPROXY_PORT="${CLIPROXY_PORT:-8317}"
    export CLIPROXY_DEBUG="${CLIPROXY_DEBUG:-false}"
    export CLIPROXY_LOGGING_TO_FILE="${CLIPROXY_LOGGING_TO_FILE:-true}"
    export CLIPROXY_ALLOW_REMOTE_MANAGEMENT="${CLIPROXY_ALLOW_REMOTE_MANAGEMENT:-false}"
    export CLIPROXY_MANAGEMENT_KEY="${CLIPROXY_MANAGEMENT_KEY:-}"
    export CLIPROXY_API_KEY

    echo "No config found — rendering ${CONFIG_FILE} from template."
    envsubst '${CLIPROXY_HOST} ${CLIPROXY_PORT} ${CLIPROXY_API_KEY} ${CLIPROXY_DEBUG} ${CLIPROXY_LOGGING_TO_FILE} ${CLIPROXY_ALLOW_REMOTE_MANAGEMENT} ${CLIPROXY_MANAGEMENT_KEY}' \
        < "${TEMPLATE_FILE}" > "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
fi

exec /CLIProxyAPI/CLIProxyAPI "$@"
