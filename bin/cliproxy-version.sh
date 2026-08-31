#!/usr/bin/env bash
#
# Resolve, lock, and export the upstream CLIProxyAPI version.
#
# All network access and all validation live here, so the Makefile can stay a
# thin wrapper (macOS ships GNU Make 3.81, which silently ignores .ONESHELL and
# .SHELLFLAGS — multi-line recipe logic there would be a portability trap).
#
# Subcommands:
#   resolve   print the newest strict tag for a major, plus its commit SHA
#   update    resolve, then rewrite the lockfile (the only writing command)
#   check     compare the lockfile against upstream; exit 1 if behind
#   export    emit shell assignments for the locked version (used by make)
#   print     print the locked version string alone
#
# Exit codes: 2 bad config/lock, 3 network/resolution, 4 no tags for that
# major, 5 refused downgrade.

set -euo pipefail
export LC_ALL=C

UPSTREAM="https://github.com/router-for-me/CLIProxyAPI.git"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${ROOT}/cliproxy.lock"

die() { local code="$1"; shift; printf 'error: %s\n' "$*" >&2; exit "$code"; }

valid_version() { printf '%s' "${1:-}" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; }
valid_sha()     { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{40}$'; }
valid_major()   { printf '%s' "${1:-}" | grep -qE '^[0-9]+$'; }

# Fetch the full remote tag list once. Never pipe ls-remote straight into a
# filter: it can emit partial output and then fail, which would silently
# resolve to a wrong "latest".
#
# GIT_TERMINAL_PROMPT=0 matters — if the repo is renamed or deleted, GitHub
# answers 404 and git otherwise blocks forever prompting for credentials.
# The low-speed settings are a git-native timeout; `timeout(1)` is not on a
# stock macOS.
fetch_tags() {
    local raw
    if ! raw=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true \
                 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
                     ls-remote --tags "$UPSTREAM" 2>&1); then
        printf 'error: cannot reach %s\n%s\n' "$UPSTREAM" "$raw" >&2
        printf 'hint: only "make update"/"make check" need the network; builds do not.\n' >&2
        exit 3
    fi
    [ -n "$raw" ] || die 3 "upstream returned an empty tag list"
    printf '%s\n' "$raw"
}

# Newest strict vMAJOR.MINOR.PATCH tag. The strict filter is load-bearing:
# upstream carries 248 non-strict tags (a v6.5.x-0 family, pre-cleanup-*).
#
# Sorting strips the leading "v" first, then sorts numerically field by field.
# Plain lexical sort is actively wrong here — it puts v7.2.99 above v7.2.146.
latest_tag() {
    local raw="$1" major="$2"
    printf '%s\n' "$raw" \
      | awk -F'\t' '{print $2}' \
      | sed -n 's|^refs/tags/||p' \
      | grep -E "^v${major}\.[0-9]+\.[0-9]+$" \
      | sed 's/^v//' \
      | sort -t. -k1,1n -k2,2n -k3,3n \
      | tail -1 \
      | sed 's/^/v/'
}

# The commit a tag really points at.
#
# For an ANNOTATED tag, refs/tags/X is the tag object and refs/tags/X^{} is the
# commit — and `git clone --branch X` lands on the commit. Upstream has 5
# annotated tags including v7.2.31, so preferring the peeled ref is required or
# SHA verification would fail permanently on those. This is also why we do not
# pass --refs, which strips the peeled lines and leaves only the tag object.
tag_commit() {
    local raw="$1" tag="$2" sha
    sha=$(printf '%s\n' "$raw" | awk -F'\t' -v t="refs/tags/${tag}^{}" '$2==t{print $1}')
    [ -n "$sha" ] || sha=$(printf '%s\n' "$raw" | awk -F'\t' -v t="refs/tags/${tag}" '$2==t{print $1}')
    printf '%s' "$sha"
}

read_lock() {
    [ -f "$LOCK" ] || die 2 "cliproxy.lock is missing — run 'make update'"
    # Parsed with an explicit allowlist; never sourced, so a malformed or
    # hostile lockfile cannot execute code.
    LOCK_VERSION=$(sed -n 's/^version=//p'     "$LOCK" | tr -d '\r' | head -1)
    LOCK_COMMIT=$( sed -n 's/^commit=//p'      "$LOCK" | tr -d '\r' | head -1)
    LOCK_DATE=$(   sed -n 's/^resolved_at=//p' "$LOCK" | tr -d '\r' | head -1)
    valid_version "$LOCK_VERSION" || die 2 "cliproxy.lock: bad version '${LOCK_VERSION}' (want vN.N.N)"
    valid_sha     "$LOCK_COMMIT"  || die 2 "cliproxy.lock: bad commit '${LOCK_COMMIT}' (want 40 hex chars)"
    [ -n "$LOCK_DATE" ] || die 2 "cliproxy.lock: missing resolved_at"
}

# Refuse to build a major the lockfile does not match. Without this, bumping
# CLIPROXY_MAJOR and forgetting to re-resolve silently keeps building the old
# track while the repo claims otherwise.
assert_major() {
    local major="$1" lock_major="${LOCK_VERSION#v}"
    lock_major="${lock_major%%.*}"
    [ "$lock_major" = "$major" ] || die 2 \
"major skew: CLIPROXY_MAJOR is ${major} but cliproxy.lock holds ${LOCK_VERSION}.
Run 'make update' to re-resolve, or restore CLIPROXY_MAJOR to ${lock_major}."
}

write_lock() {
    local version="$1" commit="$2" date="$3" tmp
    # Regenerate and rename atomically. `sed -i` is deliberately avoided: BSD
    # requires an argument, GNU rejects one.
    tmp=$(mktemp "${LOCK}.XXXXXX")
    {
        printf '# Managed by `make update`. The exact upstream build input.\n'
        printf '# commit is the resolved commit SHA; the build verifies it and fails on a mismatch.\n'
        printf 'version=%s\n'     "$version"
        printf 'commit=%s\n'      "$commit"
        printf 'resolved_at=%s\n' "$date"
        printf 'source=%s\n'      "$UPSTREAM"
    } > "$tmp"
    mv "$tmp" "$LOCK"
}

# ---------------------------------------------------------------- subcommands

cmd_resolve() {
    local major="$1" pin="${2:-}" raw tag sha
    valid_major "$major" || die 2 "CLIPROXY_MAJOR must be an integer, got '${major}'"
    raw=$(fetch_tags)

    if [ -n "$pin" ]; then
        valid_version "$pin" || die 2 "CLIPROXY_PIN must look like vN.N.N, got '${pin}'"
        sha=$(tag_commit "$raw" "$pin") || true
        [ -n "$sha" ] || die 4 "pinned tag ${pin} does not exist upstream"
        printf '%s\t%s\n' "$pin" "$sha"
        return
    fi

    # `|| true`: a no-match grep inside latest_tag returns 1, and under
    # pipefail that would abort here before the empty check below can report.
    tag=$(latest_tag "$raw" "$major") || true
    if [ -z "$tag" ]; then
        local majors
        majors=$(printf '%s\n' "$raw" | awk -F'\t' '{print $2}' | sed -n 's|^refs/tags/||p' \
                 | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | cut -d. -f1 | sort -u | tr '\n' ' ') || true
        die 4 "no strict v${major}.N.N tags exist upstream. Majors available: ${majors}"
    fi
    sha=$(tag_commit "$raw" "$tag") || true
    [ -n "$sha" ] || die 3 "resolved ${tag} but could not read its commit SHA"
    printf '%s\t%s\n' "$tag" "$sha"
}

cmd_update() {
    local major="$1" pin="${2:-}" allow_downgrade="${3:-}" resolved tag sha old="(none)"
    resolved=$(cmd_resolve "$major" "$pin")
    tag=${resolved%%$'\t'*}
    sha=${resolved##*$'\t'}

    if [ -f "$LOCK" ]; then
        old=$(sed -n 's/^version=//p' "$LOCK" | tr -d '\r' | head -1)
        local old_commit
        old_commit=$(sed -n 's/^commit=//p' "$LOCK" | tr -d '\r' | head -1)

        if [ "$old" = "$tag" ] && [ "$old_commit" = "$sha" ]; then
            # No-op on purpose: rewriting resolved_at would churn the diff and,
            # because the build uses it as BUILD_DATE, force a full Go rebuild.
            printf 'cliproxy.lock unchanged: %s\n' "$tag"
            return
        fi
        if [ "$old" = "$tag" ] && [ "$old_commit" != "$sha" ]; then
            printf 'WARNING: %s now points at a different commit upstream.\n' "$tag" >&2
            printf '  was: %s\n  now: %s\n' "$old_commit" "$sha" >&2
            printf '  The tag was moved. Review before committing the lockfile.\n' >&2
        fi
        # Refuse to walk backwards when resolving a major, which would mean
        # the newest tag vanished upstream. An explicit CLIPROXY_PIN is the
        # user deliberately choosing a version, so it is exempt.
        if [ "$old" != "$tag" ] && [ -z "$pin" ] && [ -z "$allow_downgrade" ] && valid_version "$old"; then
            local newest
            newest=$(printf '%s\n%s\n' "${old#v}" "${tag#v}" \
                     | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
            [ "v${newest}" = "$tag" ] || die 5 \
"refusing downgrade ${old} -> ${tag} (was the newer tag deleted upstream?).
Re-run with ALLOW_DOWNGRADE=1 if this is intended."
        fi
    fi

    write_lock "$tag" "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'cliproxy.lock: %s -> %s\n' "$old" "$tag"
    printf '  commit %s\n' "$sha"
    printf '  review the release notes, commit the lockfile, then: make up\n'
}

cmd_check() {
    local major="$1" pin="${2:-}" resolved tag
    read_lock
    assert_major "$major"
    resolved=$(cmd_resolve "$major" "$pin")
    tag=${resolved%%$'\t'*}
    if [ "$tag" = "$LOCK_VERSION" ]; then
        printf 'up to date: %s\n' "$LOCK_VERSION"
    else
        printf 'outdated: locked %s, newest v%s.x is %s — run '\''make update'\''\n' \
               "$LOCK_VERSION" "$major" "$tag"
        exit 1
    fi
}

# Emits single-quoted assignments. Values are already regex-validated, so they
# cannot break out of the quoting when the Makefile evals this.
cmd_export() {
    local major="$1"
    read_lock
    assert_major "$major"
    printf "CLIPROXY_VERSION='%s'\n"    "$LOCK_VERSION"
    printf "CLIPROXY_COMMIT='%s'\n"     "$LOCK_COMMIT"
    printf "CLIPROXY_BUILD_DATE='%s'\n" "$LOCK_DATE"
}

cmd_print() { read_lock; printf '%s\n' "$LOCK_VERSION"; }

# Mirror the locked version into .env.
#
# Compose interpolates the whole file on EVERY subcommand, so without this a
# bare `docker compose exec/logs/ps` would fail the required-variable guard —
# and those are the commands the README documents for provider logins. make
# re-syncs before each compose call, so the value cannot go stale underneath it.
cmd_sync() {
    local major="$1" env_file="${ROOT}/.env" tmp
    read_lock
    assert_major "$major"
    [ -f "$env_file" ] || return 0
    # All three are written, not just the version: compose validates every
    # interpolation in the file on every subcommand, so a partial sync would
    # still break `docker compose logs`.
    if [ "$(sed -n 's/^CLIPROXY_VERSION=//p'    "$env_file" | head -1)" = "$LOCK_VERSION" ] && \
       [ "$(sed -n 's/^CLIPROXY_COMMIT=//p'     "$env_file" | head -1)" = "$LOCK_COMMIT"  ] && \
       [ "$(sed -n 's/^CLIPROXY_BUILD_DATE=//p' "$env_file" | head -1)" = "$LOCK_DATE"    ]; then
        return 0
    fi
    tmp=$(mktemp "${env_file}.XXXXXX")
    grep -vE '^(CLIPROXY_VERSION|CLIPROXY_COMMIT|CLIPROXY_BUILD_DATE)=' "$env_file" > "$tmp" || true
    {
        printf '\n# Managed by make from cliproxy.lock — do not edit.\n'
        printf 'CLIPROXY_VERSION=%s\n'    "$LOCK_VERSION"
        printf 'CLIPROXY_COMMIT=%s\n'     "$LOCK_COMMIT"
        printf 'CLIPROXY_BUILD_DATE=%s\n' "$LOCK_DATE"
    } >> "$tmp"
    # .env holds secrets; keep it owner-only and never widen it.
    chmod 600 "$tmp"
    mv "$tmp" "$env_file"
    printf 'synced .env to %s\n' "$LOCK_VERSION"
}

main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        resolve) cmd_resolve "${CLIPROXY_MAJOR:?}" "${CLIPROXY_PIN:-}" ;;
        update)  cmd_update  "${CLIPROXY_MAJOR:?}" "${CLIPROXY_PIN:-}" "${ALLOW_DOWNGRADE:-}" ;;
        check)   cmd_check   "${CLIPROXY_MAJOR:?}" "${CLIPROXY_PIN:-}" ;;
        export)  cmd_export  "${CLIPROXY_MAJOR:?}" ;;
        print)   cmd_print ;;
        sync)    cmd_sync    "${CLIPROXY_MAJOR:?}" ;;
        *) printf 'usage: %s {resolve|update|check|export|print|sync}\n' "${0##*/}" >&2; exit 2 ;;
    esac
}

main "$@"
