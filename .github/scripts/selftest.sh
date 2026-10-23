#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Against fakes only: no network, no root, no KVM.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require awk sed mktemp git

FAILS=0
TESTS=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass() { TESTS=$((TESTS + 1)); }
flunk() {
    TESTS=$((TESTS + 1))
    FAILS=$((FAILS + 1))
    printf 'FAIL: %s\n' "$*" >&2
}

check() {
    local name=$1 expected=$2 actual=$3
    if [[ $expected == "$actual" ]]; then pass; else flunk "$name: expected '$expected', got '$actual'"; fi
}

check_true() {
    local name=$1
    shift
    if (set +e; "$@") >/dev/null 2>&1; then pass; else flunk "$name: expected success"; fi
}
check_false() {
    local name=$1
    shift
    if (set +e; "$@") >/dev/null 2>&1; then flunk "$name: expected failure"; else pass; fi
}

# --- digests and tags ------------------------------------------------------------------
check "tag unchanged" "libfprint-1.94.10-1.fc45-s0123456789ab" "$(oci_tag libfprint-1.94.10-1.fc45-s0123456789ab)"
check "tag sanitised" "libfprint-1.94.10_rc1-1.fc45" "$(oci_tag 'libfprint-1.94.10~rc1-1.fc45')"
check "tag leading dot" "_.hidden" "$(oci_tag .hidden)"
check "tag length" 128 "$(oci_tag "$(printf 'x%.0s' {1..300})" | tr -d '\n' | wc -c)"

# --- libfprint: the compose's repositories, never all of updates-testing ----------------
F="$TMP/fprint"
mkdir -p "$F/bin"
cat >"$F/bin/rpm" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    "-E %fedora") echo 45 ;;
    "-E %_arch") echo x86_64 ;;
    *) exit 1 ;;
esac
EOF
cat >"$F/bin/dnf5" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_DNF_LOG"
echo 'libfprint 0 1.94.100 1.fc45 libfprint-1.94.100-1.fc45.src.rpm'
EOF
chmod +x "$F/bin/rpm" "$F/bin/dnf5"
fprint_key() {
    : >"$F/dnf.log"
    PATH="$F/bin:$PATH" FAKE_DNF_LOG="$F/dnf.log" GA_REACHED=$1 TESTING_INCLUDEPKGS=$2 \
        "$APEX_ROOT/packaging/libfprint/build.sh" key 2>/dev/null
}
k_empty=$(fprint_key 0 '')
check_false "libfprint, empty allowlist: updates-testing not enabled" grep -q updates-testing "$F/dnf.log"
k_list=$(fprint_key 0 gtk4-4.24.0-1.fc45)
check_true "libfprint, allowlist: updates-testing enabled" grep -q -- '--repo=updates-testing ' "$F/dnf.log"
check_true "libfprint, allowlist: restricted by includepkgs" \
    grep -q -- '--setopt=updates-testing.includepkgs=gtk4-4.24.0-1.fc45' "$F/dnf.log"
k_ga=$(fprint_key 1 gtk4-4.24.0-1.fc45)
check_false "libfprint after GA: updates-testing not enabled" grep -q updates-testing "$F/dnf.log"
check "libfprint key names the stock NVR" libfprint-1.94.100-1.fc45-s "${k_empty%????????????}"
check_false "libfprint key changes with the repository options" test "$k_empty" = "$k_list"
check "libfprint key is the same with no updates-testing either way" "$k_empty" "$k_ga"

k_default=$(PATH="$F/bin:$PATH" FAKE_DNF_LOG="$F/dnf.log" "$APEX_ROOT/.github/scripts/libfprint.sh" key 2>/dev/null)
check "libfprint.sh defaults to Fedora 45 after GA, with no updates-testing" "$(oci_tag "$k_ga")" "$k_default"

# --- .gitignore: biometric data never gets tracked -------------------------------------
for f in a.pgm B.PGM x/print.Variant rec.ioctl x/y/rec.UMOCKDEV cap.pcap cap.PcapNG var/lib/fprint/u/1; do
    check_true ".gitignore ignores $f" git -C "$APEX_ROOT" check-ignore -q --no-index "$f"
done
check_false ".gitignore keeps the libfprint patches" \
    git -C "$APEX_ROOT" check-ignore -q --no-index packaging/libfprint/patches/README.md

if ((FAILS > 0)); then
    die "selftest: $FAILS failure(s)"
fi
log "selftest: all $TESTS checks passed"
