# CLIProxyAPI — Custom Docker Image

A production-ready Docker setup for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), built from the official source at the exact upstream tag recorded in `cliproxy.lock` (not the prebuilt `eceasy/cli-proxy-api` image).

**What you get:**

- Multi-stage build from the official GitHub source (Go 1.26, matching upstream build flags)
- Slim `debian:bookworm-slim` runtime running as a non-root user (UID 10001)
- No secrets baked into the image — config is rendered at first start from environment variables
- Persistent config, OAuth tokens, and logs via Docker volumes
- Health check on the API port
- Follows an upstream major line (`v7.x`); `make update` moves to its newest tag and records the exact tag + commit in `cliproxy.lock`

## Quick start

```bash
# 1. Enter the project directory
cd cliproxyapi-docker

# 2. Create your .env and set the required API key
cp .env.example .env
echo "Generated key: $(openssl rand -hex 32)"
# Paste the key into .env as CLIPROXY_API_KEY=<key>

# 3. Build from official source and start
make up

# 4. Check it's healthy
make ps                                 # STATUS should show (healthy)

# 5. Log in to a provider (example: Claude)
make login P=claude
# Follow the printed URL, authorize, and paste the callback URL back if prompted.

# 6. Smoke test
curl http://localhost:8317/v1/models \
  -H "Authorization: Bearer $(grep ^CLIPROXY_API_KEY .env | cut -d= -f2)"
```

The proxy now serves OpenAI/Gemini/Claude/Codex-compatible endpoints on `http://localhost:8317`.

Run `make` on its own for the full command list.

## Files

| File | Purpose |
|---|---|
| `Makefile` | Command surface, and `CLIPROXY_MAJOR` — the upstream major this repo follows |
| `cliproxy.lock` | The exact tag + commit every build uses; committed, rewritten by `make update` |
| `bin/cliproxy-version.sh` | Resolves the newest tag for the major, validates, and writes the lockfile |
| `Dockerfile` | Multi-stage build from the official source at the tag passed in as a build arg |
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
| `CLIPROXY_PORT` | `8317` | Listen port inside the container |
| `CLIPROXY_HOST` | `""` (all interfaces) | Bind interface inside the container |
| `CLIPROXY_MANAGEMENT_KEY` | `""` (management API disabled) | Key for the management API / control panel |
| `CLIPROXY_ALLOW_REMOTE_MANAGEMENT` | `false` | Allow non-localhost management access |
| `CLIPROXY_DEBUG` | `false` | Debug logging |
| `CLIPROXY_LOGGING_TO_FILE` | `true` | Write logs to the `logs` volume instead of stdout |
| `TZ` | `UTC` | Container timezone |

The upstream version is **not** an environment variable — see [Versioning](#versioning).

The rendered config covers the common settings. For advanced options (provider API keys, model aliases, routing, payload rules), edit `config/config.yaml` — the full annotated reference ships in the image at `/CLIProxyAPI/config.example.yaml`.

### Editing the config on the host

`./config/config.yaml` is bind-mounted into the container, so the file you edit on the host is the file the server reads. To apply changes:

1. **Edit and save the file — that's it for most settings.** The server watches its config and hot-reloads within a few seconds (API keys, provider credentials, routing, retries, management options).
2. **Confirm it applied** (optional): `docker logs --since 30s cli-proxy-api` — look for a `configuration updated` line. YAML syntax errors also surface here; the server keeps running on the previous config rather than crashing.

**Exceptions — listener-level settings need a restart.** `port`, `host`, and the `tls` block shape the already-bound socket, so run `make restart` after changing them. Changing the port also requires updating the compose port mapping, which needs `make up` (recreate) instead of a plain restart.

### Persistence

| Mount | Contents |
|---|---|
| `./config` (bind mount) | `config.yaml` — edit directly on the host; changes are hot-reloaded by the server |
| `cliproxy_auths` (named volume) | OAuth token JSON files from provider logins |
| `cliproxy_logs` (named volume) | Rotating log files (when `logging-to-file` is on) |

All three survive container recreation and image updates.

## Versioning

Two knobs, both at the top of the `Makefile`:

| Knob | Default | Meaning |
|---|---|---|
| `CLIPROXY_MAJOR` | `7` | Upstream major line to follow. `make update` takes its newest tag. |
| `CLIPROXY_PIN` | *(empty)* | Set to an exact tag (e.g. `v7.2.140`) to freeze. Overrides the major. |

Everything else derives from `cliproxy.lock`, which is committed and is the single source of truth for what gets built:

```
version=v7.2.146
commit=d31b15916d15b550bbf388fd6da4a47d4d864109
resolved_at=2026-08-31T21:55:53Z
source=https://github.com/router-for-me/CLIProxyAPI.git
```

Day-to-day:

```bash
make check     # is a newer v7.x out?  (exit 1 if behind)
make update    # resolve it and rewrite cliproxy.lock
git commit cliproxy.lock -m "Bump CLIProxyAPI to $(make -s version)"
make up        # build and start at the locked version
```

To move to a new major, edit `CLIPROXY_MAJOR` at the top of the `Makefile`, then `make update`. Either knob can also be overridden for a one-off without editing the file: `make update CLIPROXY_MAJOR=8`, `make update CLIPROXY_PIN=v7.2.140`.

**Builds never touch the network to choose a version.** Only `make check` and `make update` do. A rebuild months from now uses whatever `cliproxy.lock` says, so it produces the same image.

### Details worth knowing

- **Only strict `vN.N.N` tags are considered.** Upstream carries 248 tags that are not (a `v6.5.x-0` family, `pre-cleanup-*`); they are filtered out. Sorting is numeric per field — a lexical sort would rank `v7.2.99` above `v7.2.146`.
- **The commit SHA is verified at build time.** If upstream moves a tag, the build fails rather than silently producing different code. The SHA is part of the Docker layer cache key, so a moved tag genuinely rebuilds.
- **`make update` is a no-op when nothing changed**, so it will not churn the lockfile or force a needless Go recompile.
- **Downgrades are refused** when resolving a major (it usually means a tag was deleted upstream); re-run with `ALLOW_DOWNGRADE=1`. An explicit `CLIPROXY_PIN` is exempt, since that is deliberate.
- **`make` keeps a managed block in your `.env`** holding the locked version, commit, and build date. That is what lets plain `docker compose …` commands keep working; do not edit those lines by hand.

## Build and run without Compose

```bash
# Build at whatever cliproxy.lock records. `make build` does this for you;
# these are the raw commands if you need them.
eval "$(CLIPROXY_MAJOR=7 ./bin/cliproxy-version.sh export)"
docker build \
  --build-arg CLIPROXY_VERSION="$CLIPROXY_VERSION" \
  --build-arg CLIPROXY_COMMIT="$CLIPROXY_COMMIT" \
  --build-arg BUILD_DATE="$CLIPROXY_BUILD_DATE" \
  -t "cliproxyapi:$CLIPROXY_VERSION" .

# Run
docker run -d --name cli-proxy-api \
  --restart unless-stopped \
  -p 8317:8317 \
  -e CLIPROXY_API_KEY="$(openssl rand -hex 32)" \
  -v "$(pwd)/config:/CLIProxyAPI/config" \
  -v cliproxy_auths:/CLIProxyAPI/auths \
  -v cliproxy_logs:/CLIProxyAPI/logs \
  "cliproxyapi:$CLIPROXY_VERSION"
```

The port is published on `127.0.0.1` only, so the proxy is reachable just from the machine running Docker. If other devices on your LAN need access, widen the mapping to `-p 8317:8317` (compose: `"8317:8317"`) — and keep strong `api-keys` set, since everything on the network can then reach the API.

## Provider logins

OAuth tokens are stored in the `cliproxy_auths` volume and reused across restarts.

```bash
make login P=gemini    # Gemini
make login P=claude    # Claude
make login P=codex     # OpenAI / Codex
make login P=qwen      # Qwen
```

Since the container is headless, add `--no-browser` and complete the OAuth flow in your own browser. If a provider's flow requires a local callback redirect, temporarily uncomment the matching callback port in `docker-compose.yml` (Gemini 8085, Codex 1455, Claude 54545), run `make up`, log in, then remove the port again.

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

1. `make check` — reports whether a newer tag exists for your major.
2. Read the [release notes](https://github.com/router-for-me/CLIProxyAPI/releases) for config schema changes.
3. `make update` — rewrites `cliproxy.lock`. Commit it; the diff is the record of what changed.
4. Rebuild and recreate:

   ```bash
   make up
   ```

To move to a different major line, edit `CLIPROXY_MAJOR` at the top of the `Makefile` first.

Config, OAuth tokens, and logs live in volumes, so they carry over. Old images can be pruned with `docker image prune`.

## Security notes

- **No secrets in the image.** API keys live only in `.env` and the runtime-rendered `config/config.yaml` (mode 600); both are git-ignored. The image contains only templates.
- **Non-root runtime.** The server runs as `cliproxy` (UID 10001) with no shell login.
- **Management API off by default.** It is disabled entirely unless you set `CLIPROXY_MANAGEMENT_KEY`, and remote access stays blocked unless you also set `CLIPROXY_ALLOW_REMOTE_MANAGEMENT=true`.
- **Public exposure.** If the proxy must be reachable from the internet, put it behind a TLS-terminating reverse proxy (Caddy, nginx, Traefik) or enable the `tls:` block in `config/config.yaml`, and always keep strong `api-keys` set.
- **Pinned builds.** The image builds from the exact tag committed in `cliproxy.lock`, and the resolved commit SHA is verified during the build, so what you run is auditable and reproducible even if upstream moves a tag.
