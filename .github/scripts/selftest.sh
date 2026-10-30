#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Against fakes only: no network, no root, no KVM.

set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require awk sed mktemp git jq gzip openssl sha256sum patch

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

rc_of() { local rc=0; "$@" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }

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

k_passed=$(PATH="$F/bin:$PATH" FAKE_DNF_LOG="$F/dnf.log" GA_REACHED=1 "$APEX_ROOT/.github/scripts/libfprint.sh" key 2>/dev/null)
check "libfprint.sh key passes GA_REACHED to build.sh" "$(oci_tag "$k_ga")" "$k_passed"
check "libfprint.sh refuses to guess GA_REACHED" 1 \
    "$(PATH="$F/bin:$PATH" FAKE_DNF_LOG="$F/dnf.log" GA_REACHED='' rc_of "$APEX_ROOT/.github/scripts/libfprint.sh" key)"
check "libfprint.sh refuses a GA_REACHED other than 0 or 1" 1 \
    "$(PATH="$F/bin:$PATH" FAKE_DNF_LOG="$F/dnf.log" GA_REACHED=yes rc_of "$APEX_ROOT/.github/scripts/libfprint.sh" key)"

# --- kernel pins: KEY=VALUE data only, and no pkg.env for a lane to find ---------------
K="$APEX_ROOT/packaging/pkgs/kernel"
env_keys() { sed -n 's/^\([a-z0-9_]*\)=.*/\1/p' "$1" | sort -u | tr '\n' ' '; }
env_values() { sed -n "s/^$2=//p" "$1"; }
is_sha256() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }
is_fingerprint() { [[ $1 =~ ^[0-9A-F]{40}$ ]]; }
is_date() { [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }

check "kernel pkg.env: the pair recipe apex-lane requires" \
    "family=kernel-cachyos install=kernel-cachyos kernel-cachyos-core kernel-cachyos-modules kernel_env=kernel.env nvidia_env=nvidia.env source=copr-srpm " \
    "$(grep -vE '^(#|$)' "$K/pkg.env" | LC_ALL=C sort | tr '\n' ' ')"
check_true "kernel pkg.env: kernel_env and nvidia_env name files next to it" \
    test -f "$K/$(env_values "$K/pkg.env" kernel_env)" -a -f "$K/$(env_values "$K/pkg.env" nvidia_env)"
for f in kernel.env nvidia.env; do
    check "$f: only comments, blank lines and KEY=VALUE" "" "$(grep -vE '^(#.*|[a-z0-9_]+=[^ ].*|)$' "$K/$f")"
done
check "kernel.env keys" "chroot copr copr_key copr_key_expires srpm srpm_sha256 tag tag_key tag_key_expires tag_key_url tag_repo " \
    "$(env_keys "$K/kernel.env")"
for key in srpm srpm_sha256 copr_key copr_key_expires tag tag_key tag_key_expires tag_repo tag_key_url; do
    check "kernel.env: one $key" 1 "$(env_values "$K/kernel.env" "$key" | wc -l)"
done

check_true "kernel.env: srpm_sha256 is 64 hex digits" is_sha256 "$(env_values "$K/kernel.env" srpm_sha256)"
for key in copr_key tag_key; do
    check_true "kernel.env: $key is a fingerprint" is_fingerprint "$(env_values "$K/kernel.env" "$key")"
    check_true "kernel.env: ${key}_expires is a date" is_date "$(env_values "$K/kernel.env" "${key}_expires")"
done

check_true "kernel.env: tag_repo is an https git URL" \
    grep -qxE 'https://[^ ]+\.git' <<<"$(env_values "$K/kernel.env" tag_repo)"
check "kernel.env: tag_key_url is keys.openpgp.org's URL for tag_key" \
    "https://keys.openpgp.org/vks/v1/by-fingerprint/$(env_values "$K/kernel.env" tag_key)" \
    "$(env_values "$K/kernel.env" tag_key_url)"

kernel_srpm=$(env_values "$K/kernel.env" srpm)
if [[ $kernel_srpm =~ ^kernel-cachyos-0:([0-9.]+)-([0-9]+)\.cachyos[0-9]+\.fc45\.src$ ]]; then
    check "kernel.env: tag names the SRPM's release" "cachyos-${BASH_REMATCH[1]}-${BASH_REMATCH[2]}" \
        "$(env_values "$K/kernel.env" tag)"
else
    flunk "kernel.env: srpm '$kernel_srpm' is not a kernel-cachyos fc45 SRPM NEVRA"
fi

check_nvidia_env() {
    local file=$1 what=$2 key kmod_version userspace_count=0 nevra sha256 rest
    check "$what keys" "kmod_srpm kmod_srpm_sha256 negativo17_key negativo17_key_expires soak_days userspace " \
        "$(env_keys "$file")"
    for key in kmod_srpm kmod_srpm_sha256 negativo17_key negativo17_key_expires soak_days; do
        check "$what: one $key" 1 "$(env_values "$file" "$key" | wc -l)"
    done
    check_true "$what: kmod_srpm_sha256 is 64 hex digits" is_sha256 "$(env_values "$file" kmod_srpm_sha256)"
    check_true "$what: negativo17_key is a fingerprint" is_fingerprint "$(env_values "$file" negativo17_key)"
    check_true "$what: negativo17_key_expires is a date" is_date "$(env_values "$file" negativo17_key_expires)"
    check_true "$what: soak_days is a number of days" grep -qxE '[1-9][0-9]*' <<<"$(env_values "$file" soak_days)"
    kmod_version=$(env_values "$file" kmod_srpm | sed -n 's/^nvidia-kmod-3:\([0-9.]*\)-[0-9]*\.fc45\.src$/\1/p')
    check_false "$what: kmod_srpm is an nvidia-kmod fc45 SRPM NEVRA" test -z "$kmod_version"
    while read -r nevra sha256 rest; do
        userspace_count=$((userspace_count + 1))
        check_true "$what: $nevra sha256 is 64 hex digits" is_sha256 "$sha256"
        check "$what: $nevra has two fields" "" "$rest"
        check_true "$what: $nevra is an fc45 NEVRA" \
            test -n "$(sed -n '/^[a-z0-9-]*-[0-9]*:[^-]*-[^-]*\.fc45\.\(x86_64\|noarch\)$/p' <<<"$nevra")"
        case $nevra in
            nvidia-driver-selinux-*) ;;
            *) check "$what: $nevra is the kmod's driver version" "$kmod_version" \
                "$(sed -n 's/^.*-3:\([0-9.]*\)-.*$/\1/p' <<<"$nevra")" ;;
        esac
    done < <(env_values "$file" userspace)
    check_false "$what: at least one userspace RPM" test "$userspace_count" -eq 0
}
check_nvidia_env "$K/nvidia.env" nvidia.env

# --- .gitignore: biometric data never gets tracked -------------------------------------
for f in a.pgm B.PGM x/print.Variant rec.ioctl x/y/rec.UMOCKDEV cap.pcap cap.PcapNG var/lib/fprint/u/1; do
    check_true ".gitignore ignores $f" git -C "$APEX_ROOT" check-ignore -q --no-index "$f"
done
check_false ".gitignore keeps the libfprint patches" \
    git -C "$APEX_ROOT" check-ignore -q --no-index packaging/libfprint/patches/README.md

# shellcheck source=.github/scripts/selftest-kernel.sh
. "$(dirname "${BASH_SOURCE[0]}")/selftest-kernel.sh"

if ((FAILS > 0)); then
    die "selftest: $FAILS failure(s)"
fi
log "selftest: all $TESTS checks passed"
