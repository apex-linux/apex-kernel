#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# apex-lane's contract (packaging/README.md): exit 1 means the set is incomplete, the
# last line giving the reason; exit 2 means the check could not run.

set -euo pipefail

usage() {
    cat <<'EOF'
usage: source-check.sh SOURCE-DIR

Checks a kernel pair's public source set (ADR 0015, N6), as pair.sh writes it to
OUT/source:

  - srpms/ holds exactly the two SRPMs that recipe/kernel.env and recipe/nvidia.env
    pin, under their RPM file names and with their pinned sha256;
  - recipe/ holds kernel-spec.patch, series, kernel.env, nvidia.env and every patch
    the series names;
  - licenses/ holds the kernel's COPYING and GPL-2.0, and nvidia-kmod's COPYING or a
    note naming where it is;
  - README.source names the kernel;
  - SHA256SUMS lists every other file of the set, and each one matches.
EOF
}

fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
cannot() { printf 'source-check.sh cannot run: %s\n' "$*" >&2; exit 2; }

env_value() {
    local file=$1 key=$2 value
    [[ -f $dir/recipe/$file ]] || fail "recipe/$file is missing"
    value=$(sed -n "s/^$key=//p" "$dir/recipe/$file")
    [[ -n $value && $value != *$'\n'* ]] || fail "recipe/$file has no single $key"
    printf '%s\n' "$value"
}

file_of() { printf '%s.rpm\n' "$(sed -E 's/-[0-9]+:/-/' <<<"$1")"; }

series_entries() { sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$1"; }

check_srpms() {
    local kernel kmod name
    kernel=$(file_of "$(env_value kernel.env srpm)")
    kmod=$(file_of "$(env_value nvidia.env kmod_srpm)")
    for name in "$kernel" "$kmod"; do
        [[ -f $dir/srpms/$name ]] || fail "srpms/$name, which the pins name, is missing"
    done
    for name in "$dir"/srpms/*; do
        name=${name##*/}
        [[ $name == "$kernel" || $name == "$kmod" ]] || fail "srpms/$name is not an SRPM the pins name"
    done
    [[ $(sha256sum -- "$dir/srpms/$kernel" | awk '{print $1}') == "$(env_value kernel.env srpm_sha256)" ]] ||
        fail "srpms/$kernel does not have its pinned sha256"
    [[ $(sha256sum -- "$dir/srpms/$kmod" | awk '{print $1}') == "$(env_value nvidia.env kmod_srpm_sha256)" ]] ||
        fail "srpms/$kmod does not have its pinned sha256"
    printf 'ok srpms/ holds the two pinned SRPMs\n'
}

check_recipe() {
    local file entry
    for file in kernel-spec.patch series kernel.env nvidia.env; do
        [[ -s $dir/recipe/$file ]] || fail "recipe/$file is missing"
    done
    while read -r entry; do
        [[ $entry != /* && $entry != *..* ]] || fail "the series entry $entry leaves recipe/"
        [[ -s $dir/recipe/$entry ]] || fail "recipe/$entry, which the series names, is missing"
    done < <(series_entries "$dir/recipe/series")
    printf 'ok recipe/ holds the spec patch, the pins, the series and its patches\n'
}

check_licenses() {
    local file
    for file in kernel-COPYING GPL-2.0; do
        [[ -s $dir/licenses/$file ]] || fail "licenses/$file is missing"
    done
    [[ -s $dir/licenses/nvidia-kmod-COPYING || -s $dir/licenses/nvidia-kmod-COPYING.note ]] ||
        fail "licenses/nvidia-kmod-COPYING is missing, and no note says where it is"
    printf 'ok licenses/ holds the kernel and nvidia-kmod licences\n'
}

check_sums() {
    local unlisted gone mismatch
    [[ -s $dir/SHA256SUMS ]] || fail "SHA256SUMS is missing"
    unlisted=$(comm -13 <(listed_files) <(present_files) | head -n 1)
    [[ -z $unlisted ]] || fail "SHA256SUMS does not list $unlisted"
    gone=$(comm -23 <(listed_files) <(present_files) | head -n 1)
    [[ -z $gone ]] || fail "$gone, which SHA256SUMS lists, is missing"
    mismatch=$(cd -- "$dir" && sha256sum --check --strict SHA256SUMS 2>/dev/null | sed -n 's/: FAILED$//p' | head -n 1) || true
    [[ -z $mismatch ]] || fail "$mismatch does not match SHA256SUMS"
    (cd -- "$dir" && sha256sum --check --strict --quiet SHA256SUMS >/dev/null 2>&1) || fail "SHA256SUMS does not verify"
    printf 'ok SHA256SUMS lists and matches every file\n'
}

listed_files() { sed -E 's/^[0-9a-f]{64}  //' "$dir/SHA256SUMS" | LC_ALL=C sort; }
present_files() { (cd -- "$dir" && find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort); }

main() {
    case ${1:-} in -h | --help) usage; exit 0 ;; esac
    (($# == 1)) || { usage >&2; exit 2; }
    local tool
    for tool in sha256sum comm find sed awk; do
        command -v "$tool" >/dev/null || cannot "no $tool"
    done
    dir=$1
    [[ -d $dir ]] || cannot "$dir is not a directory"
    check_recipe
    check_srpms
    check_licenses
    grep -q '^kernel=.' "$dir/README.source" 2>/dev/null || fail "README.source is missing or names no kernel"
    check_sums
}

main "$@"
