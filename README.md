# CLIProxyAPI — Custom Docker Image

A production-ready Docker setup for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), built from the official source at a pinned release tag (not the prebuilt `eceasy/cli-proxy-api` image).

**What you get:**

- Multi-stage build from the official GitHub source (Go 1.26, matching upstream build flags)
- Slim `debian:bookworm-slim` runtime running as a non-root user (UID 10001)
- No secrets baked into the image — config is rendered at first start from environment variables
- Persistent config, OAuth tokens, and logs via Docker volumes
- Health check on the API port
- Pinned, overridable release version for reproducible builds and easy updates

## Quick start

```bash
# 1. Enter the project directory
cd cliproxyapi-docker

# 2. Create your .env and set the required API key
cp .env.example .env
echo "Generated key: $(openssl rand -hex 32)"
# Paste the key into .env as CLIPROXY_API_KEY=<key>

# 3. Build from official source and start
docker compose up -d --build

# 4. Check it's healthy
docker ps --filter name=cli-proxy-api   # STATUS should show (healthy)

# 5. Log in to a provider (example: Claude)
docker compose exec cli-proxy-api ./CLIProxyAPI --claude-login --no-browser
# Follow the printed URL, authorize, and paste the callback URL back if prompted.

# 6. Smoke test
curl http://localhost:8317/v1/models \
  -H "Authorization: Bearer $(grep ^CLIPROXY_API_KEY .env | cut -d= -f2)"
```

The proxy now serves OpenAI/Gemini/Claude/Codex-compatible endpoints on `http://localhost:8317`.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build from the official source at a pinned tag |
| `docker-entrypoint.sh` | Renders `config.yaml` from env vars on first start, then execs the server |
| `config.template.yaml` | Config template with secure defaults and `CLIPROXY_*` placeholders |
| `docker-compose.yml` | Service definition with volumes, ports, and health check |
| `.env.example` | Documented environment variables — copy to `.env` |

## Configuration

### Environment variables (first start only)

On first start, if `config/config.yaml` does not exist, the entrypoint renders it from `config.template.yaml` using these variables. After that, edit `config/config.yaml` directly — env vars are ignored once a config exists (delete `config/config.yaml` and restart to re-render).

| Variable | Default | Description |
|---|---|---|
| `CLIPROXY_API_KEY` | **required** | Client API key (Bearer token). Generate: `openssl rand -hex 32` |
| `CLIPROXY_VERSION` | `v7.2.146` | Release tag to build from |
| `CLIPROXY_PORT` | `8317` | Listen port inside the container |
| `CLIPROXY_HOST` | `""` (all interfaces) | Bind interface inside the container |
| `CLIPROXY_MANAGEMENT_KEY` | `""` (management API disabled) | Key for the management API / control panel |
| `CLIPROXY_ALLOW_REMOTE_MANAGEMENT` | `false` | Allow non-localhost management access |
| `CLIPROXY_DEBUG` | `false` | Debug logging |
| `CLIPROXY_LOGGING_TO_FILE` | `true` | Write logs to the `logs` volume instead of stdout |
| `TZ` | `UTC` | Container timezone |

The rendered config covers the common settings. For advanced options (provider API keys, model aliases, routing, payload rules), edit `config/config.yaml` — the full annotated reference ships in the image at `/CLIProxyAPI/config.example.yaml`.

### Editing the config on the host

`./config/config.yaml` is bind-mounted into the container, so the file you edit on the host is the file the server reads. To apply changes:

1. **Edit and save the file — that's it for most settings.** The server watches its config and hot-reloads within a few seconds (API keys, provider credentials, routing, retries, management options).
2. **Confirm it applied** (optional): `docker logs --since 30s cli-proxy-api` — look for a `configuration updated` line. YAML syntax errors also surface here; the server keeps running on the previous config rather than crashing.

**Exceptions — listener-level settings need a restart.** `port`, `host`, and the `tls` block shape the already-bound socket, so run `docker compose restart cli-proxy-api` after changing them. Changing the port also requires updating the compose port mapping, which needs `docker compose up -d` (recreate) instead of a plain restart.

### Persistence

| Mount | Contents |
|---|---|
| `./config` (bind mount) | `config.yaml` — edit directly on the host; changes are hot-reloaded by the server |
| `cliproxy_auths` (named volume) | OAuth token JSON files from provider logins |
| `cliproxy_logs` (named volume) | Rotating log files (when `logging-to-file` is on) |

All three survive container recreation and image updates.

## Build and run without Compose

```bash
# Build (pinned version, reproducible)
docker build \
  --build-arg CLIPROXY_VERSION=v7.2.146 \
  --build-arg BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  -t cliproxyapi:v7.2.146 .

# Run
docker run -d --name cli-proxy-api \
  --restart unless-stopped \
  -p 8317:8317 \
  -e CLIPROXY_API_KEY="$(openssl rand -hex 32)" \
  -v "$(pwd)/config:/CLIProxyAPI/config" \
  -v cliproxy_auths:/CLIProxyAPI/auths \
  -v cliproxy_logs:/CLIProxyAPI/logs \
  cliproxyapi:v7.2.146
```

The port is published on `127.0.0.1` only, so the proxy is reachable just from the machine running Docker. If other devices on your LAN need access, widen the mapping to `-p 8317:8317` (compose: `"8317:8317"`) — and keep strong `api-keys` set, since everything on the network can then reach the API.

## Provider logins

OAuth tokens are stored in the `cliproxy_auths` volume and reused across restarts.

```bash
docker compose exec cli-proxy-api ./CLIProxyAPI --login          # Gemini
docker compose exec cli-proxy-api ./CLIProxyAPI --claude-login   # Claude
docker compose exec cli-proxy-api ./CLIProxyAPI --codex-login    # OpenAI / Codex
docker compose exec cli-proxy-api ./CLIProxyAPI --qwen-login     # Qwen
```

Since the container is headless, add `--no-browser` and complete the OAuth flow in your own browser. If a provider's flow requires a local callback redirect, temporarily uncomment the matching callback port in `docker-compose.yml` (Gemini 8085, Codex 1455, Claude 54545), run `docker compose up -d`, log in, then remove the port again.

## Using with Claude Code

Point Claude Code at the proxy from any machine that can SSH to this host. No server-side changes are needed — everything below happens on the client.

1. **Open an SSH tunnel** (the proxy is only reachable via loopback on the server):

   ```bash
   ssh -fN -L 8317:localhost:8317 <user>@<server-ip>
   ```

2. **Add the proxy to `~/.claude/settings.json`** on the client. All three variables go inside the `env` block — a common mistake is placing them at the top level, where they are silently ignored:

   ```json
   {
     "env": {
       "ANTHROPIC_BASE_URL": "http://localhost:8317",
       "ANTHROPIC_AUTH_TOKEN": "<CLIPROXY_API_KEY from the server's .env>",
       "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1"
     }
   }
   ```

   `ANTHROPIC_AUTH_TOKEN` is the **client** API key (`CLIPROXY_API_KEY`), not the management key. The third variable is optional: it makes `/model` fetch the proxy's `/v1/models` list, so models from every logged-in provider appear in the picker (requires Claude Code v2.1.129+). Because the proxy translates protocols, selecting a non-Anthropic model there works too.

3. **Validate and restart.** An invalid settings file is ignored *entirely* — no error shown — so check it before wondering why nothing changed:

   ```bash
   python3 -m json.tool ~/.claude/settings.json
   ```

   Then fully quit and relaunch `claude` (env vars are read at startup).

4. **Verify.** `/status` should show `http://localhost:8317` as the API endpoint, and `/model` should list the gateway models. On the server, requests appear in the proxy log:

   ```bash
   docker compose exec cli-proxy-api sh -c 'tail -f /CLIProxyAPI/logs/$(ls -t /CLIProxyAPI/logs | head -1)'
   ```

Troubleshooting, in the order things usually fail:

| Symptom | Cause / fix |
|---|---|
| `connection refused` | Tunnel not running, or pointing at the wrong host |
| 401 from the proxy | Wrong key — use `CLIPROXY_API_KEY`, check for copy/paste whitespace |
| Still using your Claude subscription | Run `/logout` once; env vars then take over |
| `/model` missing gateway models | Settings file invalid or vars outside the `env` block (see step 3); confirm version ≥ 2.1.129 with `claude --version`; test with `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1 claude --debug` and look for `[gatewayDiscovery]` lines |

## Updating to a new release

1. Check the [releases page](https://github.com/router-for-me/CLIProxyAPI/releases) and read the release notes for config schema changes.
2. Bump `CLIPROXY_VERSION` in `.env` (or pass `--build-arg` if building manually).
3. Rebuild and recreate:

   ```bash
   docker compose up -d --build
   ```

Config, OAuth tokens, and logs live in volumes, so they carry over. Old images can be pruned with `docker image prune`.

## Security notes

- **No secrets in the image.** API keys live only in `.env` and the runtime-rendered `config/config.yaml` (mode 600); both are git-ignored. The image contains only templates.
- **Non-root runtime.** The server runs as `cliproxy` (UID 10001) with no shell login.
- **Management API off by default.** It is disabled entirely unless you set `CLIPROXY_MANAGEMENT_KEY`, and remote access stays blocked unless you also set `CLIPROXY_ALLOW_REMOTE_MANAGEMENT=true`.
- **Public exposure.** If the proxy must be reachable from the internet, put it behind a TLS-terminating reverse proxy (Caddy, nginx, Traefik) or enable the `tls:` block in `config/config.yaml`, and always keep strong `api-keys` set.
- **Pinned builds.** The image builds from a specific release tag, so what you run is auditable and reproducible.
