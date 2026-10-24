#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# apex-lane's contract (packaging/README.md): exit 1 holds the pair, the last line
# giving the reason; exit 2 means the job could not run.

set -euo pipefail

usage() {
    cat <<'EOF'
usage: pair.sh MIRROR OUT [DNF-OPTION...]

The kernel and NVIDIA pair job of ADR 0015, run as root in one fresh fedora:45
container:

  1. verifies every input in MIRROR against kernel.env and nvidia.env: the sha256 of
     each pinned file, and its signature against a keyring that holds only its pinned
     key (MIRROR/copr.gpg for the kernel SRPM, MIRROR/negativo17.gpg for the rest);
  2. generates the job's module key on the tmpfs MODKEY_DIR (module-key.sh);
  3. applies kernel-spec.patch and builds the kernel with rpmbuild -bb, through
     ccache when CCACHE_DIR is set;
  4. builds the kmod for that kernel (kmod-build.sh);
  5. shreds the private key;
  6. runs check.sh with MODULE_CERT;
  7. writes OUT/pair.lock and copies the RPMs to OUT/rpms.

MIRROR holds the pinned files under their RPM file names. Logs go to OUT. A reason
that starts with "kmod:" is a kmod failure on a kernel that built. DNF-OPTIONs name
the compose's repositories. MODKEY_DIR defaults to /run/apex-modkey; PAIR_ID names
the key's certificate.
EOF
}

readonly COPR_KEYRING=copr.gpg
readonly NEGATIVO17_KEYRING=negativo17.gpg
readonly LOG_TAIL_LINES=30

cannot() { printf 'pair.sh cannot run: %s\n' "$*" >&2; exit 2; }
hold() { printf '%s\n' "$*" >&2; exit 1; }

hold_with_log() {
    local log=$1
    shift
    tail -n "$LOG_TAIL_LINES" -- "$log" >&2 || true
    hold "$@"
}

env_value() {
    local file=$1 key=$2 value
    value=$(sed -n "s/^$key=//p" "$file")
    [[ -n $value && $value != *$'\n'* ]] || cannot "${file##*/} has no single $key"
    printf '%s\n' "$value"
}

file_of() {
    local nevra=$1
    printf '%s.rpm\n' "$(sed -E 's/-[0-9]+:/-/' <<<"$nevra")"
}

keyring() {
    local name=$1 key_file=$2 pinned=$3 dir=$work/keyring-$1
    [[ -s $key_file ]] || cannot "no $name key at $key_file"
    mkdir -p -- "$dir"
    rpmkeys --dbpath "$dir" --import "$key_file" || hold "the $name key file does not import"
    [[ $(rpmkeys --dbpath "$dir" --list | awk '{print $1}') == "${pinned,,}" ]] ||
        hold "the $name key file is not exactly the pinned key $pinned"
    printf '%s\n' "$dir"
}

verify_input() {
    local nevra=$1 sha256=$2 keyring=$3 file
    file=$mirror/$(file_of "$nevra")
    [[ -f $file ]] || cannot "the mirror has no $(file_of "$nevra")"
    [[ $(sha256sum -- "$file" | awk '{print $1}') == "$sha256" ]] ||
        hold "${file##*/} does not have its pinned sha256"
    rpmkeys --dbpath "$keyring" -K -- "$file" 2>&1 | grep -q 'digests signatures OK$' ||
        hold "${file##*/} is not signed by its pinned key"
}

verify_inputs() {
    local copr negativo17 nevra sha256 rest
    copr=$(keyring copr "$mirror/$COPR_KEYRING" "$(env_value "$kernel_env" copr_key)")
    negativo17=$(keyring negativo17 "$mirror/$NEGATIVO17_KEYRING" "$(env_value "$nvidia_env" negativo17_key)")
    verify_input "$kernel_srpm" "$(env_value "$kernel_env" srpm_sha256)" "$copr"
    verify_input "$kmod_srpm" "$(env_value "$nvidia_env" kmod_srpm_sha256)" "$negativo17"
    while read -r nevra sha256 rest; do
        [[ -n $sha256 && -z $rest ]] || cannot "nvidia.env has a malformed userspace line: $nevra"
        verify_input "$nevra" "$sha256" "$negativo17"
    done < <(sed -n 's/^userspace=//p' "$nvidia_env")
    printf 'ok every input has its pinned sha256 and signature\n'
}

shred_key_on_exit() {
    if [[ $key_made == 1 && -e $key_dir/signing_key.pem ]]; then
        "$here/module-key.sh" shred "$key_dir" || printf 'pair.sh: could not shred %s\n' "$key_dir" >&2
    fi
}

make_key() {
    local release=$1
    [[ -d $key_dir && -z $(ls -A -- "$key_dir") ]] || cannot "$key_dir is not an empty directory"
    key_made=1
    "$here/module-key.sh" generate "$key_dir" "Apex kernel $release $pair_id" >"$out/module-key.txt" ||
        cannot "module-key.sh could not make the job's key on $key_dir"
}

build_kernel() {
    local spec=$topdir/SPECS/kernel-cachyos.spec
    rpm --define "_topdir $topdir" -i -- "$mirror/$(file_of "$kernel_srpm")" 2>"$out/srpm-install.log" ||
        cannot "the kernel SRPM does not install"
    patch --fuzz=0 -p1 -d "$topdir/SPECS" <"$here/kernel-spec.patch" >"$out/spec-patch.log" 2>&1 ||
        hold_with_log "$out/spec-patch.log" "kernel: kernel-spec.patch does not apply with fuzz 0"
    "${dnf[@]}" builddep --define "apex_module_sig_key $key_dir/signing_key.pem" "$spec" \
        >"$out/kernel-builddep.log" 2>&1 || cannot "dnf cannot install the kernel's BuildRequires"
    if [[ -n ${CCACHE_DIR:-} ]]; then
        "${dnf[@]}" install ccache >>"$out/dnf.log" 2>&1 || cannot "dnf cannot install ccache"
        export CCACHE_DIR PATH=/usr/lib64/ccache:$PATH
    fi
    rpmbuild -bb --define "_topdir $topdir" \
        --define "apex_module_sig_key $key_dir/signing_key.pem" "$spec" >"$out/kernel.log" 2>&1 ||
        hold_with_log "$out/kernel.log" "kernel: rpmbuild -bb failed"
    printf 'ok the kernel built\n'
}

build_kmod() {
    "$here/kmod-build.sh" "$mirror/$(file_of "$kmod_srpm")" "$topdir/RPMS" "$key_dir" "$topdir" "${dnf_options[@]}" \
        >"$out/kmod.log" 2>&1 ||
        hold_with_log "$out/kmod.log" "kmod: $kmod_srpm does not build for this kernel"
    printf 'ok the kmod built\n'
}

run_checks() {
    local rc=0
    RPMS_DIR=$topdir/RPMS CHECK_WORK=$work/check MODULE_CERT=$key_dir/signing_key.x509 \
        "$here/check.sh" >"$out/check.log" 2>&1 || rc=$?
    case $rc in
        0) printf 'ok check.sh passed\n' ;;
        1) hold_with_log "$out/check.log" "check: $(tail -n 1 "$out/check.log")" ;;
        *) tail -n "$LOG_TAIL_LINES" -- "$out/check.log" >&2; cannot "check.sh could not run" ;;
    esac
}

nevr_of() {
    rpm --query --package --nosignature --queryformat '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}' -- "$1"
}

only_built() {
    local pattern=$1
    local -a found
    mapfile -t found < <(find "$topdir/RPMS" -type f -name "$pattern")
    ((${#found[@]} == 1)) || hold "expected one built $pattern, found ${#found[@]}"
    printf '%s\n' "${found[0]}"
}

write_lock() {
    local rpm kernel kmod certificate
    kernel=$(only_built 'kernel-cachyos-[0-9]*.rpm')
    kernel=$(nevr_of "$kernel")
    kmod=$(only_built 'kmod-nvidia-*.rpm')
    kmod=$(nevr_of "$kmod")
    certificate=$(sha256sum -- "$key_dir/signing_key.x509" | awk '{print $1}')
    mkdir -p -- "$out/rpms"
    find "$topdir/RPMS" -type f -name '*.rpm' -exec cp -t "$out/rpms" -- {} +
    {
        printf 'kernel=%s\n' "$kernel"
        printf 'kmod=%s\n' "$kmod"
        printf 'module_cert_sha256=%s\n' "$certificate"
        for rpm in "$out"/rpms/*.rpm; do
            printf 'rpm=%s %s\n' "${rpm##*/}" "$(sha256sum -- "$rpm" | awk '{print $1}')"
        done
    } >"$out/pair.lock.tmp"
    mv -- "$out/pair.lock.tmp" "$out/pair.lock"
    cp -- "$key_dir/signing_key.x509" "$out/signing_key.x509"
    printf 'ok wrote %s\n' "$out/pair.lock"
}

main() {
    case ${1:-} in -h | --help) usage; exit 0 ;; esac
    (($# >= 2)) || { usage >&2; exit 2; }
    mirror=$1 out=$2
    shift 2
    dnf_options=("$@")
    dnf=(dnf5 -y -q "${dnf_options[@]}")
    local tool release
    for tool in rpm rpmkeys dnf5 sha256sum; do
        command -v "$tool" >/dev/null || cannot "no $tool in the container"
    done
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    kernel_env=$here/kernel.env nvidia_env=$here/nvidia.env
    key_dir=${MODKEY_DIR:-/run/apex-modkey} pair_id=${PAIR_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
    key_made=0
    [[ -d $mirror ]] || cannot "no mirror directory $mirror"
    mkdir -p -- "$out"
    out=$(cd -- "$out" && pwd)
    work=$(mktemp -d) topdir=$work/topdir
    trap shred_key_on_exit EXIT
    trap 'exit 130' INT TERM

    kernel_srpm=$(env_value "$kernel_env" srpm)
    kmod_srpm=$(env_value "$nvidia_env" kmod_srpm)
    release=$(sed -E 's/^kernel-cachyos-[0-9]+:(.*)\.src$/\1/' <<<"$kernel_srpm").x86_64
    verify_inputs
    "${dnf[@]}" install rpm-build dnf5-plugins patch openssl perl-Math-BigInt file diffutils binutils kmod \
        cpio xz zstd findutils >"$out/dnf.log" 2>&1 || cannot "dnf cannot install the job's tools"
    for tool in rpmbuild patch openssl; do
        command -v "$tool" >/dev/null || cannot "no $tool after dnf install"
    done
    make_key "$release"
    build_kernel
    build_kmod
    "$here/module-key.sh" shred "$key_dir" || cannot "module-key.sh could not shred the job's key"
    run_checks
    write_lock
}

main "$@"
