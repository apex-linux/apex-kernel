#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
usage: [VMLINUX=FILE] kmod-build.sh NVIDIA-KMOD-SRPM KERNEL-RPMS-DIR KEY-DIR TOPDIR [DNF-OPTION...]

Builds negativo17's nvidia-kmod for exactly one kernel, in the container that just
built that kernel (ADR 0015). It installs the kernel-cachyos-devel of KERNEL-RPMS-DIR,
rebuilds the SRPM unmodified through kmodtool for that one uname -r, and has kmodtool
sign every module with the key of KEY-DIR (module-key.sh). The kmod-nvidia RPM lands
under TOPDIR/RPMS. DNF-OPTIONs name the compose's repositories.

VMLINUX is that kernel's vmlinux, with its .BTF: kbuild generates a module's BTF
against it, and kernel-cachyos-devel ships none, so without it the modules carry no
BTF. Run it as root. check.sh, not this script, proves that the modules are signed.
EOF
}

die() { printf 'kmod-build.sh: %s\n' "$*" >&2; exit 1; }

only_file() {
    local dir=$1 pattern=$2
    local -a found
    mapfile -t found < <(find "$dir" -type f -name "$pattern")
    ((${#found[@]} == 1)) || die "expected one $pattern under $dir, found ${#found[@]}"
    printf '%s\n' "${found[0]}"
}

kernel_release_of() {
    rpm --query --package --nosignature --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' -- "$1"
}

# NVIDIA: the modules "must be built with the toolchain that was used to build the kernel".
require_the_kernels_compiler() {
    local kernel_tree=$1 kernel_gcc_major container_gcc_major
    kernel_gcc_major=$(sed -n 's/^CONFIG_GCC_VERSION=\([0-9]*\)[0-9]\{4\}$/\1/p' "$kernel_tree/.config")
    container_gcc_major=$(gcc -dumpversion | cut -d. -f1)
    [[ -n $kernel_gcc_major && $kernel_gcc_major == "$container_gcc_major" ]] ||
        die "the kernel was built with GCC ${kernel_gcc_major:-unknown}, this container has GCC $container_gcc_major"
}

# negativo17's spec passes only KERNEL_UNAME, so NVIDIA's makefile looks for the kernel
# tree under /lib/modules; kernel-cachyos-modules owns that link, -devel does not.
link_the_kernel_tree() {
    local release=$1 kernel_tree=$2
    mkdir -p -- "/lib/modules/$release"
    ln -sfn -- "$kernel_tree" "/lib/modules/$release/build"
}

main() {
    case ${1:-} in -h | --help) usage; exit 0 ;; esac
    (($# >= 4)) || { usage >&2; exit 2; }
    local srpm=$1 kernel_rpms=$2 key_dir=$3 topdir=$4
    shift 4
    local -a dnf=(dnf5 -y -q "$@")
    local devel release kernel_tree
    [[ -s $key_dir/signing_key.pem && -s $key_dir/signing_key.x509 ]] ||
        die "no module key in $key_dir: kmodtool would leave the modules unsigned without a word"
    devel=$(only_file "$kernel_rpms" 'kernel-cachyos-devel-[0-9]*.rpm')
    release=$(kernel_release_of "$devel")
    kernel_tree=/usr/src/kernels/$release

    "${dnf[@]}" install rpm-build dnf5-plugins kmodtool dwarves "$devel"
    "${dnf[@]}" builddep "$srpm"
    require_the_kernels_compiler "$kernel_tree"
    link_the_kernel_tree "$release" "$kernel_tree"
    if [[ -n ${VMLINUX:-} ]]; then
        [[ -s $VMLINUX ]] || die "VMLINUX names no file: $VMLINUX"
        cp -- "$VMLINUX" "$kernel_tree/vmlinux"
    fi

    rpmbuild --rebuild \
        --define "_topdir $topdir" \
        --define "kernels $release" \
        --define "_kmodtool_signmodules_privkey $key_dir/signing_key.pem" \
        --define "_kmodtool_signmodules_pubkey $key_dir/signing_key.x509" \
        "$srpm"
    only_file "$topdir/RPMS" "kmod-nvidia-$release-[0-9]*.rpm"
}

main "$@"
