# CLIProxyAPI — Custom Docker Image

A production-ready Docker setup for [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) plus the [CPA Usage Keeper](https://github.com/Willxup/cpa-usage-keeper) statistics dashboard — both built from official source at the exact upstream tags recorded in `cliproxy.lock` (not the prebuilt images).

**What you get:**

- Multi-stage build from the official GitHub source (Go 1.26, matching upstream build flags)
- Slim `debian:bookworm-slim` runtime running as a non-root user (UID 10001)
- No secrets baked into the image — config is rendered at first start from environment variables
- Persistent config, OAuth tokens, and logs via Docker volumes
- Health check on the API port
- Follows an upstream major line per component (CPA `v7.x`, keeper `v1.x`); `make update` moves each to its newest tag and records the exact tags + commits in `cliproxy.lock`
- Bundled usage-statistics dashboard (requests, tokens, cost, latency) persisted in SQLite, password-protected, loopback-only

## Quick start

```bash
# 1. Enter the project directory
cd cliproxyapi-docker

# 2. Create your .env and set the required keys
cp .env.example .env
openssl rand -hex 32   # -> CLIPROXY_API_KEY        (client API key)
openssl rand -hex 32   # -> CLIPROXY_MANAGEMENT_KEY (the usage keeper authenticates with it)
openssl rand -hex 32   # -> KEEPER_LOGIN_PASSWORD   (usage dashboard login)
# Paste each into .env

# 3. Build from official source and start
make up

# 4. Check it's healthy
make ps    # both containers should show (healthy); the keeper waits for the proxy

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
| `Makefile` | Command surface, and the `*_MAJOR` knobs — the upstream majors this repo follows |
| `cliproxy.lock` | The exact tags + commits every build uses (both upstreams); committed, rewritten by `make update` |
| `bin/cliproxy-version.sh` | Resolves the newest tag for each major, validates, and writes the lockfile |
| `Dockerfile` | Multi-stage CPA build from the official source at the tag passed in as a build arg |
| `Dockerfile.keeper` | Multi-stage cpa-usage-keeper build (clone + commit verify, Node web bundle + Go) |
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
| `CLIPROXY_MANAGEMENT_KEY` | `""` | Management API key — effectively required: the usage keeper authenticates with it |
| `KEEPER_LOGIN_PASSWORD` | **required** | Usage dashboard login password (the keeper refuses to start without it) |
| `CLIPROXY_ALLOW_REMOTE_MANAGEMENT` | `true` | Allow non-localhost management access — required: the keeper connects over the compose network |
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
| `keeper_data` (named volume) | Usage keeper SQLite database, logs, and scheduled backups |

All three survive container recreation and image updates.

## Versioning

Four knobs, all at the top of the `Makefile` — a major line and an optional exact pin per component:

| Knob | Default | Meaning |
|---|---|---|
| `CLIPROXY_MAJOR` | `7` | CLIProxyAPI major line to follow. `make update` takes its newest tag. |
| `CLIPROXY_PIN` | *(empty)* | Exact CPA tag (e.g. `v7.2.140`) to freeze. Overrides the major. |
| `KEEPER_MAJOR` | `1` | cpa-usage-keeper major line to follow. |
| `KEEPER_PIN` | *(empty)* | Exact keeper tag (e.g. `v1.14.0`) to freeze. |

Everything else derives from `cliproxy.lock`, which is committed and is the single source of truth for what gets built:

```
version=v7.2.146
commit=d31b15916d15b550bbf388fd6da4a47d4d864109
resolved_at=2026-08-31T21:55:53Z
source=https://github.com/router-for-me/CLIProxyAPI.git
keeper_version=v1.15.0
keeper_commit=696a4659ce1d5d6f2d2d0530e3205eb51fbce889
keeper_resolved_at=2026-08-31T22:42:12Z
keeper_source=https://github.com/Willxup/cpa-usage-keeper.git
```

Day-to-day:

```bash
make check     # is a newer tag out for either component?  (exit 1 if so)
make update    # resolve both and rewrite cliproxy.lock
git commit cliproxy.lock -m "Bump $(make -s version)"
make up        # build and start at the locked versions
```

To move to a new major, edit the matching `*_MAJOR` knob at the top of the `Makefile`, then `make update`. Any knob can also be overridden for a one-off without editing the file: `make update CLIPROXY_MAJOR=8`, `make update KEEPER_PIN=v1.14.0`.

**Builds never touch the network to choose a version.** Only `make check` and `make update` do. A rebuild months from now uses whatever `cliproxy.lock` says, so it produces the same images.

### Details worth knowing

- **Only strict `vN.N.N` tags are considered.** Upstream carries 248 tags that are not (a `v6.5.x-0` family, `pre-cleanup-*`); they are filtered out. Sorting is numeric per field — a lexical sort would rank `v7.2.99` above `v7.2.146`.
- **The commit SHA is verified at build time.** If upstream moves a tag, the build fails rather than silently producing different code. The SHA is part of the Docker layer cache key, so a moved tag genuinely rebuilds.
- **`make update` is a no-op when nothing changed**, so it will not churn the lockfile or force a needless Go recompile.
- **Downgrades are refused** when resolving a major (it usually means a tag was deleted upstream); re-run with `ALLOW_DOWNGRADE=1`. An explicit `CLIPROXY_PIN` is exempt, since that is deliberate.
- **An unchanged component keeps its `resolved_at` byte-for-byte** across `make update`. That value feeds the build date, so bumping one component never forces the other to rebuild.
- **An active `*_PIN` makes `make check` compare against the pin**, not the newest tag — a pinned component reports "up to date" even while its major line moves on.
- **`make` keeps a managed six-line block in your `.env`** holding both locked versions, commits, and build dates. That is what lets plain `docker compose …` commands keep working; do not edit those lines by hand.

## Usage statistics

The stack includes [CPA Usage Keeper](https://github.com/Willxup/cpa-usage-keeper), a dashboard that persists per-request usage — requests, tokens, cost estimates, cache rates, latency — in SQLite (the `keeper_data` volume, with scheduled backups).

- **Access**: the dashboard is published on `127.0.0.1:8080` only. From another machine, tunnel it like the proxy: `ssh -fN -L 8080:localhost:8080 user@server`, then open `http://localhost:8080` and log in with `KEEPER_LOGIN_PASSWORD`.
- **How it collects**: the keeper talks to the proxy over the compose-internal network — the management API (authenticated with `CLIPROXY_MANAGEMENT_KEY`) plus the usage queue on the same port. New configs are rendered with `usage-statistics-enabled: true`; nothing else needs enabling.
- **No events yet?** Usage events are generated per upstream model call. A request that never reaches a provider (e.g. before any provider login) records nothing — log in to a provider and send one request through the proxy.
- **Privacy**: the keeper's community-ranking feature is opt-in; nothing is sent anywhere by default.
- **Opting out**: remove the `cpa-usage-keeper` service from `docker-compose.yml` and set `usage-statistics-enabled: false` in `config/config.yaml` (hot-reloads).

## Build and run without Compose

```bash
# Build at whatever cliproxy.lock records. `make build` does this for you;
# these are the raw commands if you need them.
eval "$(CLIPROXY_MAJOR=7 KEEPER_MAJOR=1 ./bin/cliproxy-version.sh export)"
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

The keeper builds the same way:

```bash
docker build -f Dockerfile.keeper \
  --build-arg KEEPER_VERSION="$KEEPER_VERSION" \
  --build-arg KEEPER_COMMIT="$KEEPER_COMMIT" \
  --build-arg BUILD_DATE="$KEEPER_BUILD_DATE" \
  -t "cpa-usage-keeper:$KEEPER_VERSION" .

docker run -d --name cpa-usage-keeper \
  --restart unless-stopped \
  -p 127.0.0.1:8080:8080 \
  -e CPA_BASE_URL=http://<proxy-address>:8317 \
  -e REDIS_QUEUE_ADDR=<proxy-address>:8317 \
  -e CPA_MANAGEMENT_KEY=<management-key> \
  -e LOGIN_PASSWORD=<dashboard-password> \
  -v keeper_data:/data \
  "cpa-usage-keeper:$KEEPER_VERSION"
```

The ports are published on `127.0.0.1` only, so the proxy and dashboard are reachable just from the machine running Docker. If other devices on your LAN need access, widen the mapping to `-p 8317:8317` (compose: `"8317:8317"`) — and keep strong `api-keys` set, since everything on the network can then reach the API.

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

1. `make check` — reports whether a newer tag exists for either component.
2. Read the release notes ([CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI/releases), [cpa-usage-keeper](https://github.com/Willxup/cpa-usage-keeper/releases)) for config schema changes.
3. `make update` — rewrites `cliproxy.lock`. Commit it; the diff is the record of what changed, and only the component that moved gets rebuilt.
4. Rebuild and recreate:

   ```bash
   make up
   ```

To move to a different major line, edit the matching `*_MAJOR` knob at the top of the `Makefile` first.

### Migrating a deployment that predates the usage keeper

The rendered `config/config.yaml` is never re-rendered, and old lockfiles have no keeper entries, so three one-time steps are needed:

1. `make update` — every other command hard-fails with `cliproxy.lock has no keeper entries` until this runs once. Commit the lock; the CPA lines stay byte-identical.
2. Add to `.env`: `KEEPER_LOGIN_PASSWORD=<openssl rand -hex 32>`; set `CLIPROXY_MANAGEMENT_KEY` if it is empty; set `CLIPROXY_ALLOW_REMOTE_MANAGEMENT=true`.
3. Edit the live `config/config.yaml`: add `usage-statistics-enabled: true`, and under `remote-management:` set `allow-remote: true` and your `secret-key`. Both hot-reload — no restart, no re-render.

Then `make up`: the proxy is rebuilt only if its lock entry changed; the keeper builds and starts alongside it.

Config, OAuth tokens, and logs live in volumes, so they carry over. Old images can be pruned with `docker image prune`.

## Security notes

- **No secrets in the image.** API keys live only in `.env` and the runtime-rendered `config/config.yaml` (mode 600); both are git-ignored. The image contains only templates.
- **Non-root runtime.** The server runs as `cliproxy` (UID 10001) with no shell login.
- **Management API is enabled in this stack** — the usage keeper depends on it. Every call requires `CLIPROXY_MANAGEMENT_KEY` (the proxy stores only a bcrypt hash of it), and it is reachable only from the host's loopback and from containers on the compose network; `allow-remote: true` refers to that internal network, not the LAN. Leave the key empty to disable the management API entirely (the keeper then collects nothing).
- **The usage dashboard is loopback-published and password-gated.** Port 8080 binds to `127.0.0.1`, login protection is on by default, and the keeper container is not given your `.env` — it never sees `CLIPROXY_API_KEY`.
- **Keeper runs as a non-root user** (`app`), though its entrypoint starts as root to fix `/data` volume ownership before dropping privileges via su-exec — that is upstream's design, unlike the proxy image which starts directly as `cliproxy`.
- **Public exposure.** If the proxy must be reachable from the internet, put it behind a TLS-terminating reverse proxy (Caddy, nginx, Traefik) or enable the `tls:` block in `config/config.yaml`, and always keep strong `api-keys` set.
- **Pinned builds.** Both images build from the exact tags committed in `cliproxy.lock`, and each resolved commit SHA is verified during its build, so what you run is auditable and reproducible even if upstream moves a tag.
