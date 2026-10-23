#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat >&2 <<'EOF'

Run packaging/libfprint/build.sh inside registry.fedoraproject.org/fedora:45 (build: as
root), with the image compose's repository switches.

  libfprint.sh key            print the cache key as an OCI tag
  libfprint.sh build OUTDIR   rebuild; exit 0 built, 3 degraded, anything else failed

Environment: GA_REACHED (0 or 1, required) and TESTING_INCLUDEPKGS [empty], which
apex-image passes from its Containerfile and updates-testing allowlist.
EOF
    exit 2
}

readonly BUILD_SH="$APEX_ROOT/packaging/libfprint/build.sh"
readonly EXIT_DEGRADED=3

build_env() {
    [[ ${GA_REACHED:-} == [01] ]] ||
        die "GA_REACHED must be 0 or 1, as apex-image's Containerfile sets it; got '${GA_REACHED:-}'"
    TESTING_INCLUDEPKGS=${TESTING_INCLUDEPKGS:-}
    export GA_REACHED TESTING_INCLUDEPKGS
    log "GA_REACHED=$GA_REACHED; updates-testing allowlist: ${TESTING_INCLUDEPKGS:-<empty>}"
}

cmd_key() {
    [[ -x $BUILD_SH ]] || die "missing executable $BUILD_SH"
    build_env
    local key
    key=$("$BUILD_SH" key)
    [[ -n $key ]] || die "build.sh key printed nothing"
    oci_tag "$key"
}

cmd_build() {
    (($# == 1)) || die "usage: libfprint.sh build OUTDIR"
    [[ -x $BUILD_SH ]] || die "missing executable $BUILD_SH"
    build_env
    local rc=0
    OUT_DIR=$1 "$BUILD_SH" build || rc=$?
    case $rc in
        0)
            (cd "$1" && sha256sum -- *.rpm >SHA256SUMS)
            summary "### libfprint" "" '```' "$(cat "$1/manifest.txt")" '```'
            ;;
        "$EXIT_DEGRADED")
            summary "### libfprint: degraded" "" \
                "The patched build cannot ship; the image uses Fedora's stock libfprint and" \
                "is labelled \`degraded=fingerprint\` (ADR 0006)." "" '```' \
                "$(cat "$1/degraded.txt" 2>/dev/null || echo 'no degraded.txt')" '```'
            ;;
        *) ;;
    esac
    return "$rc"
}

main() {
    local cmd=${1:-}
    shift || true
    case $cmd in
        key) cmd_key "$@" ;;
        build) cmd_build "$@" ;;
        *) usage ;;
    esac
}

main "$@"
