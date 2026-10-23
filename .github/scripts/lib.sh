# shellcheck shell=bash disable=SC2034 # constants and helpers for the scripts that source this file
# SPDX-License-Identifier: GPL-3.0-or-later

APEX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly APEX_ROOT

in_github_actions() { [[ ${GITHUB_ACTIONS:-} == true ]]; }

log() { printf '%s\n' "$*" >&2; }

warn() {
    if in_github_actions; then printf '::warning::%s\n' "$*" >&2; else printf 'warning: %s\n' "$*" >&2; fi
}

die() {
    if in_github_actions; then printf '::error::%s\n' "$*" >&2; else printf 'error: %s\n' "$*" >&2; fi
    exit 1
}

require() {
    local missing=() c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    ((${#missing[@]} == 0)) || die "missing required tools: ${missing[*]}"
}

summary() {
    if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
        printf '%s\n' "$@" >>"$GITHUB_STEP_SUMMARY"
    else
        printf '%s\n' "$@" >&2
    fi
}

oci_tag() {
    local t
    t=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')
    t=${t:0:128}
    [[ $t =~ ^[A-Za-z0-9_] ]] || t="_${t:0:127}"
    printf '%s\n' "$t"
}
