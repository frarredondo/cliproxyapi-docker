# ─── Version policy ──────────────────────────────────────────────────────────
# The only two knobs. Everything else derives from cliproxy.lock.

# CLIProxyAPI major line to follow; `make update` takes its newest tag.
CLIPROXY_MAJOR ?= 7
# Set to an exact tag (e.g. v7.2.140) to freeze; overrides the major.
CLIPROXY_PIN   ?=
# cpa-usage-keeper major line to follow; `make update` takes its newest tag.
KEEPER_MAJOR   ?= 1
# Set to an exact tag (e.g. v1.14.0) to freeze; overrides the major.
KEEPER_PIN     ?=

# ─────────────────────────────────────────────────────────────────────────────
# Override either for a one-off without editing this file:
#     make update CLIPROXY_MAJOR=8
#     make update CLIPROXY_PIN=v7.2.140
#
# macOS ships GNU Make 3.81, which silently ignores .ONESHELL and .SHELLFLAGS.
# So every recipe line is its own shell and all real logic lives in the script.

export CLIPROXY_MAJOR
export CLIPROXY_PIN
export KEEPER_MAJOR
export KEEPER_PIN

V := ./bin/cliproxy-version.sh

.DEFAULT_GOAL := help
.PHONY: help version check update build up down restart logs ps sh login rebuild

help: ## Show this help
	@printf 'CLIProxyAPI docker — CPA v$(CLIPROXY_MAJOR).x + usage keeper v$(KEEPER_MAJOR).x\n'
	@printf 'locked at: %s\n\n' "$$($(V) print 2>/dev/null || echo '(no lockfile — run make update)')"
	@awk -F':.*## ' '/^[a-z][a-z-]*:.*## /{printf "  make %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

version: ## Print the locked versions
	@$(V) print

check: ## Is a newer tag available for either major? (exit 1 if behind)
	@$(V) check

update: ## Resolve the newest tags for both majors and rewrite cliproxy.lock
	@$(V) update

build: ## Build both images at the locked versions
	@$(V) preflight
	@$(V) sync
	@eval "$$($(V) export)" && docker compose build --pull

up: ## Build if needed and start
	@$(V) preflight
	@$(V) sync
	@eval "$$($(V) export)" && docker compose up -d --build

rebuild: ## Force a full rebuild, ignoring the layer cache
	@$(V) preflight
	@$(V) sync
	@eval "$$($(V) export)" && docker compose build --no-cache --pull

# The compose file requires CLIPROXY_VERSION, so even read-only subcommands go
# through sync — that keeps `make logs`/`ps`/`sh` working from a clean checkout.
down: ## Stop and remove the containers
	@$(V) sync
	@eval "$$($(V) export)" && docker compose down

restart: ## Restart both services (needed after port/host/tls changes)
	@$(V) sync
	@eval "$$($(V) export)" && docker compose restart

logs: ## Follow container logs
	@$(V) sync
	@eval "$$($(V) export)" && docker compose logs -f

ps: ## Show container status
	@$(V) sync
	@eval "$$($(V) export)" && docker compose ps

sh: ## Shell inside a container (default proxy; make sh S=cpa-usage-keeper)
	@$(V) sync
	@eval "$$($(V) export)" && docker compose exec $(if $(S),$(S),cli-proxy-api) sh

login: ## Provider login:  make login P=gemini|claude|codex|qwen
	@case "$(P)" in gemini) f=--login;; claude|codex|qwen) f=--$(P)-login;; *) echo "usage: make login P=gemini|claude|codex|qwen"; exit 1;; esac; \
	 $(V) sync; \
	 eval "$$($(V) export)" && docker compose exec cli-proxy-api ./CLIProxyAPI $$f --no-browser
