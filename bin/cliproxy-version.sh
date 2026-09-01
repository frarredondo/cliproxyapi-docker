#!/usr/bin/env bash
#
# Resolve, lock, and export the upstream versions this stack builds:
#   cpa    — CLIProxyAPI itself
#   keeper — cpa-usage-keeper, the usage-statistics dashboard
#
# All network access and all validation live here, so the Makefile can stay a
# thin wrapper (macOS ships GNU Make 3.81, which silently ignores .ONESHELL and
# .SHELLFLAGS — multi-line recipe logic there would be a portability trap).
# Target shell is bash 3.2 (macOS): no associative arrays, no namerefs.
#
# Subcommands:
#   resolve    print the newest strict tag + commit SHA for each component
#   update     resolve, then rewrite the lockfile (the only writing command)
#   check      compare the lockfile against upstream; exit 1 if either is behind
#   export     emit shell assignments for the locked versions (used by make)
#   print      print the locked versions on one line
#   sync       mirror the locked values into .env for bare docker compose use
#   preflight  warn (never fail) about missing runtime secrets in .env
#
# Exit codes: 2 bad config/lock, 3 network/resolution, 4 no tags for that
# major, 5 refused downgrade.

set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${ROOT}/cliproxy.lock"
COMPONENTS="cpa keeper"

# ---- per-component accessors (bash 3.2: no associative arrays) --------------
comp_upstream() { case "$1" in cpa) printf 'https://github.com/router-for-me/CLIProxyAPI.git';; keeper) printf 'https://github.com/Willxup/cpa-usage-keeper.git';; esac; }
comp_label()    { case "$1" in cpa) printf 'CLIProxyAPI';; keeper) printf 'cpa-usage-keeper';; esac; }
comp_var()      { case "$1" in cpa) printf 'CLIPROXY';;    keeper) printf 'KEEPER';;           esac; }
# Lock key names: CPA keys stay unprefixed so pre-existing locks remain valid.
comp_key()      { case "$1" in cpa) printf '%s' "$2";;     keeper) printf 'keeper_%s' "$2";;   esac; }
comp_major()    { case "$1" in cpa) printf '%s' "${CLIPROXY_MAJOR:?}";; keeper) printf '%s' "${KEEPER_MAJOR:?}";; esac; }
comp_pin()      { case "$1" in cpa) printf '%s' "${CLIPROXY_PIN:-}";;   keeper) printf '%s' "${KEEPER_PIN:-}";;   esac; }

die() { local code="$1"; shift; printf 'error: %s\n' "$*" >&2; exit "$code"; }

valid_version() { printf '%s' "${1:-}" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; }
valid_sha()     { printf '%s' "${1:-}" | grep -qE '^[0-9a-f]{40}$'; }
valid_major()   { printf '%s' "${1:-}" | grep -qE '^[0-9]+$'; }

# Fetch a remote's full tag list once. Never pipe ls-remote straight into a
# filter: it can emit partial output and then fail, which would silently
# resolve to a wrong "latest".
#
# GIT_TERMINAL_PROMPT=0 matters — if the repo is renamed or deleted, GitHub
# answers 404 and git otherwise blocks forever prompting for credentials.
# The low-speed settings are a git-native timeout; `timeout(1)` is not on a
# stock macOS.
fetch_tags() {
    local url="$1" raw
    if ! raw=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/true \
                 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
                     ls-remote --tags "$url" 2>&1); then
        printf 'error: cannot reach %s\n%s\n' "$url" "$raw" >&2
        printf 'hint: only "make update"/"make check" need the network; builds do not.\n' >&2
        exit 3
    fi
    [ -n "$raw" ] || die 3 "upstream returned an empty tag list for ${url}"
    printf '%s\n' "$raw"
}

# Newest strict vMAJOR.MINOR.PATCH tag. The strict filter is load-bearing:
# CPA upstream carries 248 non-strict tags (a v6.5.x-0 family, pre-cleanup-*).
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
# commit — and `git clone --branch X` lands on the commit. Both upstreams have
# annotated tags (CPA: v7.2.31; keeper: one as well), so preferring the peeled
# ref is required or SHA verification would fail permanently on those. This is
# also why we do not pass --refs, which strips the peeled lines and leaves only
# the tag object.
tag_commit() {
    local raw="$1" tag="$2" sha
    sha=$(printf '%s\n' "$raw" | awk -F'\t' -v t="refs/tags/${tag}^{}" '$2==t{print $1}')
    [ -n "$sha" ] || sha=$(printf '%s\n' "$raw" | awk -F'\t' -v t="refs/tags/${tag}" '$2==t{print $1}')
    printf '%s' "$sha"
}

# Raw (unvalidated, possibly empty) lock value for a component field.
lock_raw() {
    local comp="$1" field="$2"
    [ -f "$LOCK" ] || return 0
    sed -n "s/^$(comp_key "$comp" "$field")=//p" "$LOCK" | tr -d '\r' | head -1
}

# Read and validate one component's lock entry into LOCK_VERSION/COMMIT/DATE.
# Parsed with a sed allowlist; never sourced, so a malformed or hostile
# lockfile cannot execute code.
read_lock() {
    local comp="$1" label
    label=$(comp_label "$comp")
    [ -f "$LOCK" ] || die 2 "cliproxy.lock is missing — run 'make update'"
    LOCK_VERSION=$(lock_raw "$comp" version)
    LOCK_COMMIT=$( lock_raw "$comp" commit)
    LOCK_DATE=$(   lock_raw "$comp" resolved_at)
    if [ "$comp" = "keeper" ] && [ -z "${LOCK_VERSION}${LOCK_COMMIT}${LOCK_DATE}" ]; then
        die 2 "cliproxy.lock has no keeper entries — run 'make update' once"
    fi
    valid_version "$LOCK_VERSION" || die 2 "cliproxy.lock: bad ${label} version '${LOCK_VERSION}' (want vN.N.N)"
    valid_sha     "$LOCK_COMMIT"  || die 2 "cliproxy.lock: bad ${label} commit '${LOCK_COMMIT}' (want 40 hex chars)"
    [ -n "$LOCK_DATE" ] || die 2 "cliproxy.lock: missing ${label} resolved_at"
}

# Refuse to build a major the lockfile does not match. Without this, bumping
# a *_MAJOR knob and forgetting to re-resolve silently keeps building the old
# track while the repo claims otherwise.
assert_major() {
    local comp="$1" major lock_major
    major=$(comp_major "$comp")
    valid_major "$major" || die 2 "$(comp_var "$comp")_MAJOR must be an integer, got '${major}'"
    lock_major="${LOCK_VERSION#v}"
    lock_major="${lock_major%%.*}"
    [ "$lock_major" = "$major" ] || die 2 \
"major skew: $(comp_var "$comp")_MAJOR is ${major} but cliproxy.lock holds $(comp_label "$comp") ${LOCK_VERSION}.
Run 'make update' to re-resolve, or restore $(comp_var "$comp")_MAJOR to ${lock_major}."
}

# Resolve one component to "tag<TAB>sha" (newest for its major, or its pin).
resolve_component() {
    local comp="$1" major pin raw tag sha
    major=$(comp_major "$comp")
    pin=$(comp_pin "$comp")
    valid_major "$major" || die 2 "$(comp_var "$comp")_MAJOR must be an integer, got '${major}'"
    raw=$(fetch_tags "$(comp_upstream "$comp")")

    if [ -n "$pin" ]; then
        valid_version "$pin" || die 2 "$(comp_var "$comp")_PIN must look like vN.N.N, got '${pin}'"
        sha=$(tag_commit "$raw" "$pin") || true
        [ -n "$sha" ] || die 4 "pinned tag ${pin} does not exist upstream ($(comp_label "$comp"))"
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
        die 4 "no strict v${major}.N.N tags exist upstream for $(comp_label "$comp"). Majors available: ${majors}"
    fi
    sha=$(tag_commit "$raw" "$tag") || true
    [ -n "$sha" ] || die 3 "resolved $(comp_label "$comp") ${tag} but could not read its commit SHA"
    printf '%s\t%s\n' "$tag" "$sha"
}

# Rewrite the whole lockfile atomically. `sed -i` is deliberately avoided:
# BSD requires an argument, GNU rejects one.
write_lock() {
    # $1..$3 cpa version/commit/date, $4..$6 keeper version/commit/date
    local tmp
    tmp=$(mktemp "${LOCK}.XXXXXX")
    {
        printf '# Managed by `make update`. The exact upstream build inputs.\n'
        printf '# commits are resolved SHAs; each build verifies its own and fails on a mismatch.\n'
        printf 'version=%s\n'            "$1"
        printf 'commit=%s\n'             "$2"
        printf 'resolved_at=%s\n'        "$3"
        printf 'source=%s\n'             "$(comp_upstream cpa)"
        printf 'keeper_version=%s\n'     "$4"
        printf 'keeper_commit=%s\n'      "$5"
        printf 'keeper_resolved_at=%s\n' "$6"
        printf 'keeper_source=%s\n'      "$(comp_upstream keeper)"
    } > "$tmp"
    mv "$tmp" "$LOCK"
}

# ---------------------------------------------------------------- subcommands

cmd_resolve() {
    local comp resolved
    for comp in $COMPONENTS; do
        resolved=$(resolve_component "$comp")
        printf '%s\t%s\n' "$comp" "$resolved"
    done
}

cmd_update() {
    local comp resolved tag sha old_v old_c old_d new_d changed=0
    local out_v out_c out_d line lines=""

    for comp in $COMPONENTS; do
        resolved=$(resolve_component "$comp")
        tag=${resolved%%$'\t'*}
        sha=${resolved##*$'\t'}
        # Old values read tolerantly: a pre-keeper lock must not block the
        # update that adds the keeper entries.
        old_v=$(lock_raw "$comp" version)
        old_c=$(lock_raw "$comp" commit)
        old_d=$(lock_raw "$comp" resolved_at)

        if [ "$old_v" = "$tag" ] && [ "$old_c" = "$sha" ] && [ -n "$old_d" ]; then
            # Unchanged component keeps its resolved_at byte-identical: it
            # feeds BUILD_DATE, so churning it would force a needless full
            # rebuild of an image whose inputs did not change.
            new_d="$old_d"
            line="  $(comp_label "$comp"): unchanged at ${tag}"
        else
            changed=1
            new_d=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            if [ "$old_v" = "$tag" ] && [ -n "$old_c" ] && [ "$old_c" != "$sha" ]; then
                printf 'WARNING: %s %s now points at a different commit upstream.\n' "$(comp_label "$comp")" "$tag" >&2
                printf '  was: %s\n  now: %s\n' "$old_c" "$sha" >&2
                printf '  The tag was moved. Review before committing the lockfile.\n' >&2
            fi
            # Refuse to walk backwards when resolving a major, which would
            # mean the newest tag vanished upstream. An explicit pin is the
            # user deliberately choosing a version, so it is exempt.
            if [ -n "$old_v" ] && [ "$old_v" != "$tag" ] && [ -z "$(comp_pin "$comp")" ] \
               && [ -z "${ALLOW_DOWNGRADE:-}" ] && valid_version "$old_v"; then
                local newest
                newest=$(printf '%s\n%s\n' "${old_v#v}" "${tag#v}" \
                         | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
                [ "v${newest}" = "$tag" ] || die 5 \
"refusing $(comp_label "$comp") downgrade ${old_v} -> ${tag} (was the newer tag deleted upstream?).
Re-run with ALLOW_DOWNGRADE=1 if this is intended."
            fi
            line="  $(comp_label "$comp"): ${old_v:-(none)} -> ${tag}  (${sha})"
        fi
        # Stash per-component results (exactly two components; values are
        # regex-validated so eval is safe).
        eval "out_v_${comp}=\"\$tag\" out_c_${comp}=\"\$sha\" out_d_${comp}=\"\$new_d\""
        lines="${lines}${line}
"
    done

    if [ "$changed" = "0" ]; then
        printf 'cliproxy.lock unchanged: %s %s + %s %s\n' \
               "$(comp_label cpa)" "$out_v_cpa" "$(comp_label keeper)" "$out_v_keeper"
        return
    fi
    write_lock "$out_v_cpa" "$out_c_cpa" "$out_d_cpa" \
               "$out_v_keeper" "$out_c_keeper" "$out_d_keeper"
    printf 'cliproxy.lock updated:\n%s' "$lines"
    printf '  review the release notes, commit the lockfile, then: make up\n'
}

cmd_check() {
    local comp resolved tag behind=0
    for comp in $COMPONENTS; do
        read_lock "$comp"
        assert_major "$comp"
        resolved=$(resolve_component "$comp")
        tag=${resolved%%$'\t'*}
        if [ "$tag" = "$LOCK_VERSION" ]; then
            printf 'up to date: %s %s\n' "$(comp_label "$comp")" "$LOCK_VERSION"
        else
            printf 'outdated: %s locked %s, newest v%s.x is %s — run '\''make update'\''\n' \
                   "$(comp_label "$comp")" "$LOCK_VERSION" "$(comp_major "$comp")" "$tag"
            behind=1
        fi
    done
    [ "$behind" = "0" ] || exit 1
}

# Emits single-quoted assignments. Values are already regex-validated, so they
# cannot break out of the quoting when the Makefile evals this.
cmd_export() {
    local comp
    for comp in $COMPONENTS; do
        read_lock "$comp"
        assert_major "$comp"
        printf "%s_VERSION='%s'\n"    "$(comp_var "$comp")" "$LOCK_VERSION"
        printf "%s_COMMIT='%s'\n"     "$(comp_var "$comp")" "$LOCK_COMMIT"
        printf "%s_BUILD_DATE='%s'\n" "$(comp_var "$comp")" "$LOCK_DATE"
    done
}

cmd_print() {
    local comp out=""
    for comp in $COMPONENTS; do
        read_lock "$comp"
        out="${out}${out:+ + }$(comp_label "$comp") ${LOCK_VERSION}"
    done
    printf '%s\n' "$out"
}

# Mirror the locked values into .env.
#
# Compose interpolates the whole file on EVERY subcommand, so without this a
# bare `docker compose exec/logs/ps` would fail the required-variable guards —
# and those are the commands the README documents for provider logins. make
# re-syncs before each compose call, so the values cannot go stale underneath it.
cmd_sync() {
    local env_file="${ROOT}/.env" tmp comp
    local v_cpa c_cpa d_cpa v_keeper c_keeper d_keeper
    for comp in $COMPONENTS; do
        read_lock "$comp"
        assert_major "$comp"
        eval "v_${comp}=\"\$LOCK_VERSION\" c_${comp}=\"\$LOCK_COMMIT\" d_${comp}=\"\$LOCK_DATE\""
    done
    [ -f "$env_file" ] || return 0
    if [ "$(sed -n 's/^CLIPROXY_VERSION=//p'    "$env_file" | head -1)" = "$v_cpa" ] && \
       [ "$(sed -n 's/^CLIPROXY_COMMIT=//p'     "$env_file" | head -1)" = "$c_cpa" ] && \
       [ "$(sed -n 's/^CLIPROXY_BUILD_DATE=//p' "$env_file" | head -1)" = "$d_cpa" ] && \
       [ "$(sed -n 's/^KEEPER_VERSION=//p'      "$env_file" | head -1)" = "$v_keeper" ] && \
       [ "$(sed -n 's/^KEEPER_COMMIT=//p'       "$env_file" | head -1)" = "$c_keeper" ] && \
       [ "$(sed -n 's/^KEEPER_BUILD_DATE=//p'   "$env_file" | head -1)" = "$d_keeper" ]; then
        return 0
    fi
    tmp=$(mktemp "${env_file}.XXXXXX")
    grep -vE '^(CLIPROXY_VERSION|CLIPROXY_COMMIT|CLIPROXY_BUILD_DATE|KEEPER_VERSION|KEEPER_COMMIT|KEEPER_BUILD_DATE)=' "$env_file" > "$tmp" || true
    {
        printf '\n# Managed by make from cliproxy.lock — do not edit.\n'
        printf 'CLIPROXY_VERSION=%s\n'    "$v_cpa"
        printf 'CLIPROXY_COMMIT=%s\n'     "$c_cpa"
        printf 'CLIPROXY_BUILD_DATE=%s\n' "$d_cpa"
        printf 'KEEPER_VERSION=%s\n'      "$v_keeper"
        printf 'KEEPER_COMMIT=%s\n'       "$c_keeper"
        printf 'KEEPER_BUILD_DATE=%s\n'   "$d_keeper"
    } >> "$tmp"
    # .env holds secrets; keep it owner-only and never widen it.
    chmod 600 "$tmp"
    mv "$tmp" "$env_file"
    printf 'synced .env to %s %s + %s %s\n' \
           "$(comp_label cpa)" "$v_cpa" "$(comp_label keeper)" "$v_keeper"
}

# Warn (never fail) about missing runtime secrets. The keeper container
# refuses to start without them; the proxy itself is unaffected either way.
cmd_preflight() {
    local env_file="${ROOT}/.env"
    [ -f "$env_file" ] || return 0
    if [ -z "$(sed -n 's/^CLIPROXY_MANAGEMENT_KEY=//p' "$env_file" | head -1)" ]; then
        printf 'WARNING: CLIPROXY_MANAGEMENT_KEY is empty in .env — the usage keeper\n' >&2
        printf '         authenticates to the proxy with it and will not collect data.\n' >&2
        printf '         Generate one:  openssl rand -hex 32\n' >&2
    fi
    if [ -z "$(sed -n 's/^KEEPER_LOGIN_PASSWORD=//p' "$env_file" | head -1)" ]; then
        printf 'WARNING: KEEPER_LOGIN_PASSWORD is empty in .env — the cpa-usage-keeper\n' >&2
        printf '         container will refuse to start until it is set. The proxy\n' >&2
        printf '         itself is unaffected. Generate one:  openssl rand -hex 32\n' >&2
    fi
    return 0
}

main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        resolve)   cmd_resolve ;;
        update)    cmd_update ;;
        check)     cmd_check ;;
        export)    cmd_export ;;
        print)     cmd_print ;;
        sync)      cmd_sync ;;
        preflight) cmd_preflight ;;
        *) printf 'usage: %s {resolve|update|check|export|print|sync|preflight}\n' "${0##*/}" >&2; exit 2 ;;
    esac
}

main "$@"
