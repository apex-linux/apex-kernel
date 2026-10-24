#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# apex-lane's contract (packaging/README.md): exit 1 holds the pair, the last line
# giving the reason; exit 2 means the job could not run.

set -euo pipefail

usage() {
    cat <<'EOF'
usage: APEX_RELEASE=N pair.sh MIRROR OUT [DNF-OPTION...]

The kernel and NVIDIA pair job of ADR 0015, run as root in one fresh fedora:FEDORA
container (FEDORA defaults to 45):

  1. verifies every input in MIRROR against kernel.env and nvidia.env: the sha256 of
     each pinned file, and its signature against a keyring that holds only its pinned
     key (MIRROR/copr.gpg for the kernel SRPM, MIRROR/negativo17.gpg for the rest);
  2. generates the job's module key on the tmpfs MODKEY_DIR (module-key.sh);
  3. applies kernel-spec.patch and builds the kernel with rpmbuild -bb, release
     <cachyos release>.apexN, applying the patches that series names, through
     ccache when CCACHE_DIR is set; keeps OUT/debug/vmlinux, OUT/debug/System.map
     and OUT/debug/config from the build tree, then removes the tree, and holds the
     pair when vmlinux has no .BTF section;
  4. builds the kmod for that kernel (kmod-build.sh);
  5. shreds the private key;
  6. runs check.sh with MODULE_CERT;
  7. writes the public source set to OUT/source (both SRPMs as verified, the recipe,
     the licences, README.source and SHA256SUMS) and checks it with source-check.sh;
  8. writes OUT/pair.lock and copies the RPMs to OUT/rpms.

On every exit once OUT exists, OUT/timings gives the seconds of each stage reached
(verify, dnf, key, kernel_builddep, kernel, kmod, check, source), with ccache's hits,
misses and size when CCACHE_DIR is set, and the total, as KEY=VALUE lines.

When the kmod fails, the kernel can still ship without NVIDIA (degraded=nvidia): after
the shred, check.sh runs with CHECK_SCOPE=kernel, and OUT gets kernel.lock (pair.lock
without the kmod line) and the kernel RPMs. The exit stays 1 with a "kmod:" reason;
a failed kernel check gives a "check:" reason and no kernel.lock.

MIRROR holds the pinned files under their RPM file names. Logs go to OUT, the
kernel build's as OUT/debug/kernel.log. A reason
that starts with "kmod:" is a kmod failure on a kernel that built. DNF-OPTIONs name
the compose's repositories. FEDORA picks the pins: 45 reads kernel.env and nvidia.env
next to pair.sh, any other release fedora-FEDORA/; their chroot and every NEVRA must
be that release's. MODKEY_DIR defaults to /run/apex-modkey; PAIR_ID names
the key's certificate.

APEX_PAIR_FAULT=kmod is a test hook for the lane's rehearsals: the kmod build fails
without running, and the job takes the kmod-failure path above. Unset or empty, it
does nothing; any other value is refused with exit 2.
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

release_pins() {
    fedora=${FEDORA:-45}
    [[ $fedora =~ ^[1-9][0-9]+$ ]] || cannot "FEDORA is a Fedora release number, not '$fedora'"
    if [[ $fedora == 45 ]]; then
        pins=$here
    else
        pins=$here/fedora-$fedora
    fi
    [[ -f $pins/kernel.env && -f $pins/nvidia.env ]] ||
        cannot "no fedora-$fedora pins: ${pins#"$here/"}/kernel.env and nvidia.env are not both there"
    kernel_env=$pins/kernel.env nvidia_env=$pins/nvidia.env
}

# Pins of another release must never build or report as this one's.
require_release_pins() {
    local chroot_pin kernel_pin kmod_pin nevra
    chroot_pin=$(env_value "$kernel_env" chroot)
    kernel_pin=$(env_value "$kernel_env" srpm)
    kmod_pin=$(env_value "$nvidia_env" kmod_srpm)
    [[ $chroot_pin == "fedora-$fedora-x86_64" ]] ||
        cannot "kernel.env's chroot is $chroot_pin, not fedora-$fedora-x86_64"
    for nevra in "$kernel_pin" "$kmod_pin"; do
        [[ $nevra == *".fc$fedora.src" ]] || cannot "$nevra is not a .fc$fedora SRPM"
    done
    while read -r nevra _; do
        [[ $nevra =~ \.fc$fedora\.(x86_64|noarch)$ ]] || cannot "nvidia.env's $nevra is not a .fc$fedora RPM"
    done < <(sed -n 's/^userspace=//p' "$nvidia_env")
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

# Each stage's seconds run until the next stage starts, or until the job exits.
stage() {
    [[ -z $stage_name ]] || stage_seconds+=("$stage_name=$((SECONDS - stage_start))")
    stage_name=$1 stage_start=$SECONDS
}

ccache_stats() {
    ccache --print-stats 2>/dev/null | awk -F '\t' '
        $1 == "direct_cache_hit" || $1 == "preprocessed_cache_hit" { hits += $2 }
        $1 == "cache_miss" { misses = $2 }
        $1 == "cache_size_kibibyte" { size = $2 }
        END { printf "ccache_hits=%d\nccache_misses=%d\nccache_size_kib=%d\n", hits, misses, size }'
}

write_timings() {
    stage ''
    {
        ((${#stage_seconds[@]} == 0)) || printf '%s\n' "${stage_seconds[@]}"
        ((ccache_used == 0)) || ccache_stats
        printf 'total=%d\n' "$SECONDS"
    } >"$out/timings" 2>/dev/null || true
}

on_exit() {
    shred_key_on_exit
    write_timings
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
    stage kernel_builddep
    "${dnf[@]}" builddep "${spec_defines[@]}" "$spec" \
        >"$out/kernel-builddep.log" 2>&1 || cannot "dnf cannot install the kernel's BuildRequires"
    if [[ -n ${CCACHE_DIR:-} ]]; then
        "${dnf[@]}" install ccache >>"$out/dnf.log" 2>&1 || cannot "dnf cannot install ccache"
        export CCACHE_DIR PATH=/usr/lib64/ccache:$PATH
        ccache --zero-stats >/dev/null || cannot "ccache cannot reset its statistics"
        ccache_used=1
    fi
    stage kernel
    rpmbuild -bb --noclean --define "_topdir $topdir" "${spec_defines[@]}" "$spec" >"$out/debug/kernel.log" 2>&1 ||
        hold_with_log "$out/debug/kernel.log" "kernel: rpmbuild -bb failed"
    printf 'ok the kernel built\n'
    keep_build_files
}

# rpmbuild's rmbuild stage would delete the tree; --noclean leaves it for this copy.
keep_build_files() {
    local -a trees
    mapfile -t trees < <(find "$topdir/BUILD" -mindepth 3 -maxdepth 3 -type f -name vmlinux -printf '%h\n')
    ((${#trees[@]} == 1)) || hold "kernel: expected one build tree with vmlinux, found ${#trees[@]}"
    if ! cp -- "${trees[0]}/vmlinux" "${trees[0]}/System.map" "$out/debug/" ||
        ! cp -- "${trees[0]}/.config" "$out/debug/config"; then
        hold "kernel: the build tree lacks System.map or .config"
    fi
    mkdir -p -- "$work/licenses"
    if ! cp -- "${trees[0]}/COPYING" "$work/licenses/kernel-COPYING" ||
        ! cp -- "${trees[0]}/LICENSES/preferred/GPL-2.0" "$work/licenses/GPL-2.0"; then
        hold "kernel: the build tree lacks COPYING or LICENSES/preferred/GPL-2.0"
    fi
    rm -rf -- "$topdir/BUILD"
    printf 'ok kept vmlinux, System.map, config and the kernel licences\n'
    require_btf "$out/debug/vmlinux"
}

# CONFIG_DEBUG_INFO_BTF=y in the config does not prove that pahole wrote the section.
require_btf() {
    local sections
    sections=$(readelf --section-headers --wide -- "$1" 2>/dev/null) || hold "kernel: readelf cannot read vmlinux"
    grep -qE '[[:space:]]\.BTF[[:space:]]' <<<"$sections" || hold "kernel: vmlinux has no .BTF section"
    printf 'ok vmlinux has a .BTF section\n'
}

build_kmod() {
    if [[ $fault == kmod ]]; then
        printf 'pair.sh: APEX_PAIR_FAULT=kmod: the kmod build did not run\n' >"$out/kmod.log"
        return 1
    fi
    "$here/kmod-build.sh" "$mirror/$(file_of "$kmod_srpm")" "$topdir/RPMS" "$key_dir" "$topdir" "${dnf_options[@]}" \
        >"$out/kmod.log" 2>&1 || return 1
    printf 'ok the kmod built\n'
}

run_checks() {
    local scope=$1 rc=0
    RPMS_DIR=$topdir/RPMS CHECK_WORK=$work/check-$scope MODULE_CERT=$key_dir/signing_key.x509 CHECK_SCOPE=$scope \
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

nvidia_licence() {
    local dir=$1 srpm
    srpm=$mirror/$(file_of "$kmod_srpm")
    if rpm2cpio "$srpm" 2>/dev/null | cpio -i --quiet --to-stdout '*.tar.gz' 2>/dev/null |
        tar -xzO --wildcards --no-wildcards-match-slash '*/COPYING' >"$dir/nvidia-kmod-COPYING" 2>/dev/null &&
        [[ -s $dir/nvidia-kmod-COPYING ]]; then
        return
    fi
    rm -f -- "$dir/nvidia-kmod-COPYING"
    printf '%s\n' "nvidia-kmod's licence is the file COPYING at the top of the source tarball inside" \
        "srpms/${srpm##*/}; the spec's License field reads:" \
        "$(rpm --query --package --nosignature --queryformat '%{LICENSE}' -- "$srpm" 2>/dev/null || echo unknown)" \
        >"$dir/nvidia-kmod-COPYING.note"
}

write_source_readme() {
    local kernel=$1 kmod=$2 series_path=recipe/series
    cat <<EOF
Apex kernel pair: public source (ADR 0015, N6)

kernel=$kernel
kmod=$kmod
tag=$(env_value "$kernel_env" tag)
tag_repo=$(env_value "$kernel_env" tag_repo)
apex_release=${apex_release:-unset}
kernel_srpm=srpms/$(file_of "$kernel_srpm")
nvidia_kmod_srpm=srpms/$(file_of "$kmod_srpm")

To rebuild the kernel (fedora:$fedora, as root):
  rpm -i srpms/$(file_of "$kernel_srpm")
  cd ~/rpmbuild/SPECS && patch --fuzz=0 -p1 < /path/to/this/recipe/kernel-spec.patch
  rpmbuild -bb --define 'apex_release ${apex_release:-N}' \\
      --define 'apex_series /path/to/this/$series_path' \\
      --define 'apex_module_sig_key /path/to/your/signing_key.pem' kernel-cachyos.spec
The spec's %prep applies the patches $series_path names, in order, after the CachyOS
ones. Then the NVIDIA modules for that kernel:
  rpmbuild --rebuild --define 'kernels <uname -r of that kernel>' srpms/$(file_of "$kmod_srpm")

The licences are in licenses/. SHA256SUMS covers every file here; source-check.sh in
apex-kernel's packaging/pkgs/kernel/ checks the set.
EOF
}

write_source() {
    local kmod_nevra=$1 src=$out/source entry kernel_nevra
    kernel_nevra=$(only_built 'kernel-cachyos-[0-9]*.rpm')
    kernel_nevra=$(nevr_of "$kernel_nevra")
    rm -rf -- "$src"
    mkdir -p -- "$src/srpms" "$src/recipe" "$src/licenses"
    cp -- "$mirror/$(file_of "$kernel_srpm")" "$mirror/$(file_of "$kmod_srpm")" "$src/srpms/"
    cp -- "$here/kernel-spec.patch" "$here/series" "$kernel_env" "$nvidia_env" "$src/recipe/"
    while read -r entry; do
        [[ -f $here/$entry ]] || hold "source: the series names $entry, which is missing"
        mkdir -p -- "$src/recipe/$(dirname -- "$entry")"
        cp -- "$here/$entry" "$src/recipe/$entry"
    done < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$here/series")
    cp -- "$work/licenses/kernel-COPYING" "$work/licenses/GPL-2.0" "$src/licenses/"
    nvidia_licence "$src/licenses"
    write_source_readme "$kernel_nevra" "$kmod_nevra" >"$src/README.source"
    (cd -- "$src" && find . -type f ! -name SHA256SUMS -printf '%P\0' | LC_ALL=C sort -z | xargs -0 sha256sum --) \
        >"$work/SHA256SUMS"
    mv -- "$work/SHA256SUMS" "$src/SHA256SUMS"
    "$here/source-check.sh" "$src" >"$out/source-check.log" 2>&1 ||
        hold_with_log "$out/source-check.log" "source: $(tail -n 1 "$out/source-check.log")"
    printf 'ok wrote and checked %s\n' "$src"
}

write_lock() {
    local lock=$1 rpm kernel kmod='' certificate
    kernel=$(only_built 'kernel-cachyos-[0-9]*.rpm')
    kernel=$(nevr_of "$kernel")
    if [[ $lock == pair.lock ]]; then
        kmod=$(only_built 'kmod-nvidia-*.rpm')
        kmod=$(nevr_of "$kmod")
    fi
    certificate=$(sha256sum -- "$key_dir/signing_key.x509" | awk '{print $1}')
    mkdir -p -- "$out/rpms"
    if [[ -n $kmod ]]; then
        find "$topdir/RPMS" -type f -name '*.rpm' -exec cp -t "$out/rpms" -- {} +
    else
        find "$topdir/RPMS" -type f -name '*.rpm' ! -name 'kmod-nvidia-*' -exec cp -t "$out/rpms" -- {} +
    fi
    {
        printf 'kernel=%s\n' "$kernel"
        [[ -z $kmod ]] || printf 'kmod=%s\n' "$kmod"
        printf 'module_cert_sha256=%s\n' "$certificate"
        for rpm in "$out"/rpms/*.rpm; do
            printf 'rpm=%s %s\n' "${rpm##*/}" "$(sha256sum -- "$rpm" | awk '{print $1}')"
        done
    } >"$out/$lock.tmp"
    mv -- "$out/$lock.tmp" "$out/$lock"
    cp -- "$key_dir/signing_key.x509" "$out/signing_key.x509"
    printf 'ok wrote %s\n' "$out/$lock"
}

main() {
    case ${1:-} in -h | --help) usage; exit 0 ;; esac
    (($# >= 2)) || { usage >&2; exit 2; }
    mirror=$1 out=$2
    shift 2
    fault=${APEX_PAIR_FAULT:-} apex_release=${APEX_RELEASE:-}
    [[ $apex_release =~ ^[1-9][0-9]*$ ]] || cannot "APEX_RELEASE is the N of the .apexN release, not '$apex_release'"
    [[ -z $fault || $fault == kmod ]] || cannot "APEX_PAIR_FAULT is kmod or empty, not '$fault'"
    dnf_options=("$@")
    dnf=(dnf5 -y -q "${dnf_options[@]}")
    local tool release
    for tool in rpm rpmkeys dnf5 sha256sum; do
        command -v "$tool" >/dev/null || cannot "no $tool in the container"
    done
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    release_pins
    require_release_pins
    key_dir=${MODKEY_DIR:-/run/apex-modkey} pair_id=${PAIR_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
    key_made=0
    [[ -d $mirror ]] || cannot "no mirror directory $mirror"
    mkdir -p -- "$out/debug"
    out=$(cd -- "$out" && pwd)
    work=$(mktemp -d) topdir=$work/topdir
    stage_name='' stage_start=0 ccache_used=0
    stage_seconds=()
    trap on_exit EXIT
    trap 'exit 130' INT TERM

    kernel_srpm=$(env_value "$kernel_env" srpm)
    kmod_srpm=$(env_value "$nvidia_env" kmod_srpm)
    [[ -f $here/series ]] || cannot "no series file next to pair.sh"
    spec_defines=(--define "apex_release $apex_release" --define "apex_series $here/series"
        --define "apex_module_sig_key $key_dir/signing_key.pem")
    release=$(sed -E "s/^kernel-cachyos-[0-9]+:(.*)\.(fc[0-9]+)\.src$/\1.apex$apex_release.\2/" <<<"$kernel_srpm").x86_64
    stage verify
    verify_inputs
    stage dnf
    "${dnf[@]}" install rpm-build dnf5-plugins patch openssl perl-Math-BigInt file diffutils binutils kmod \
        cpio tar xz zstd findutils >"$out/dnf.log" 2>&1 || cannot "dnf cannot install the job's tools"
    for tool in rpmbuild patch openssl readelf; do
        command -v "$tool" >/dev/null || cannot "no $tool after dnf install"
    done
    stage key
    make_key "$release"
    build_kernel
    stage kmod
    local kmod_built=1 kmod_nevra
    build_kmod || kmod_built=0
    "$here/module-key.sh" shred "$key_dir" || cannot "module-key.sh could not shred the job's key"
    if ((kmod_built)); then
        stage check
        run_checks pair
        kmod_nevra=$(only_built 'kmod-nvidia-*.rpm')
        kmod_nevra=$(nevr_of "$kmod_nevra")
        stage source
        write_source "$kmod_nevra"
        write_lock pair.lock
    else
        stage check
        run_checks kernel
        stage source
        write_source "none: the kmod did not build"
        write_lock kernel.lock
        hold_with_log "$out/kmod.log" "kmod: $kmod_srpm does not build for this kernel"
    fi
}

main "$@"
