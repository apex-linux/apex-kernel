#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    cat <<'EOF'
usage: pair-inputs.sh tags
       pair-inputs.sh collect DIR
       GITHUB_REPOSITORY=OWNER/REPO pair-inputs.sh publish DIR

The pair's durable input mirror (owner-approved 2026-11-15): one GitHub release per
side, so that a kernel can pair with an older driver.

  pair-inputs-kernel-<kernel SRPM NVR>            the kernel SRPM and the COPR's pubkey.gpg
  pair-inputs-nvidia-<kmod version>-<kmod release> the kmod SRPM, every userspace RPM and
                                                   negativo17's RPM-GPG-KEY-slaanesh

Each file is an asset under the basename of its upstream URL, with <basename>.sha256
beside it. A release only grows: nothing is replaced or deleted.

tags     prints the two release names for the pins next to this script.
collect  downloads both sides into DIR/kernel and DIR/nvidia, from the URLs apex-lane
         fetches them from. Each key must be exactly its pinned fingerprint, each RPM
         its pinned sha256 and signed by its pinned key alone. Only when every file of
         both sides passes does it write the .sha256 files and DIR/verified.
publish  for each side, compares every asset the release already holds under one of
         DIR's names, then uploads the ones it lacks. A differing asset refuses the
         whole publish before anything is uploaded.

Each file's verdict (verified, refused, present, added) goes to stdout and, in Actions,
to the job summary. Exit 1 when an input fails its pin or a release differs; the
reason is on the last line. Exit 2 when the script cannot run.
EOF
}

readonly COPR_RESULTS=https://download.copr.fedorainfracloud.org/results
readonly NEGATIVO17_REPOS=https://negativo17.org/repos/nvidia
readonly NEGATIVO17_KEY_URL=https://negativo17.org/repos/RPM-GPG-KEY-slaanesh

cannot() { printf 'pair-inputs.sh cannot run: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'pair-inputs.sh: %s\n' "$*" >&2; exit 1; }

verdict() {
    printf '%s %s %s\n' "$1" "$2" "$3"
    [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || printf '| %s | %s | %s |\n' "$2" "$3" "$1" >>"$GITHUB_STEP_SUMMARY"
}

env_value() {
    local file=$1 key=$2 value
    value=$(sed -n "s/^$key=//p" "$file")
    [[ -n $value && $value != *$'\n'* ]] || cannot "${file##*/} has no single $key"
    printf '%s\n' "$value"
}

# NAME-EPOCH:VERSION-RELEASE.ARCH, as apex-lane's Nevra::parse splits it.
nevra_parts() {
    [[ $1 =~ ^(.+)-([0-9]+):([^-]+)-([^-]+)\.([a-z0-9_]+)$ ]] || cannot "not a NEVRA: $1"
    printf '%s %s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
}

file_of() {
    local name version release arch
    read -r name version release arch < <(nevra_parts "$1")
    printf '%s-%s-%s.%s.rpm\n' "$name" "$version" "$release" "$arch"
}

kernel_tag() {
    local name version release _
    read -r name version release _ < <(nevra_parts "$(env_value "$kernel_env" srpm)")
    printf 'pair-inputs-kernel-%s-%s-%s\n' "$name" "$version" "$release"
}

nvidia_tag() {
    local _ version release
    read -r _ version release _ < <(nevra_parts "$(env_value "$nvidia_env" kmod_srpm)")
    printf 'pair-inputs-nvidia-%s-%s\n' "$version" "$release"
}

fetch() {
    local url=$1 to=$2
    curl --fail --silent --show-error --location --retry 3 --output "$to" -- "$url" || {
        verdict refused "${to##*/}" "not served"
        refuse "cannot download $url"
    }
}

# Sets keyring_db to a keyring that holds KEY-FILE, which must be exactly PINNED.
keyring() {
    local key_file=$1 pinned=$2
    keyring_db=$(mktemp -d)
    if ! rpmkeys --dbpath "$keyring_db" --import "$key_file" 2>/dev/null ||
        [[ $(rpmkeys --dbpath "$keyring_db" --list | awk '{print $1}') != "${pinned,,}" ]]; then
        verdict refused "${key_file##*/}" "not the pinned key"
        refuse "${key_file##*/} is not exactly the pinned key $pinned"
    fi
    verdict verified "${key_file##*/}" "key $pinned"
}

verify_rpm() {
    local file=$1 sha256=$2 db=$3
    if [[ $(sha256sum -- "$file" | awk '{print $1}') != "$sha256" ]]; then
        verdict refused "${file##*/}" "sha256 is not the pin"
        refuse "${file##*/} does not have its pinned sha256"
    fi
    if ! rpmkeys --dbpath "$db" -K -- "$file" 2>&1 | grep -q 'digests signatures OK$'; then
        verdict refused "${file##*/}" "not signed by its pinned key"
        refuse "${file##*/} is not signed by its pinned key"
    fi
    verdict verified "${file##*/}" "sha256 and signature"
}

negativo17_url() {
    local dir=x86_64
    [[ $1 != *.src ]] || dir=SRPMS
    printf '%s/fedora-%s/%s/%s\n' "$NEGATIVO17_REPOS" "$fedora" "$dir" "$(file_of "$1")"
}

collect() {
    local dir=$1 copr chroot file nevra sha256 rest side name
    [[ -d $dir && -z $(ls -A -- "$dir") ]] || cannot "$dir is not an empty directory"
    mkdir -- "$dir/kernel" "$dir/nvidia"
    copr=$(env_value "$kernel_env" copr)
    chroot=$(env_value "$kernel_env" chroot)
    fetch "$COPR_RESULTS/$copr/pubkey.gpg" "$dir/kernel/pubkey.gpg"
    keyring "$dir/kernel/pubkey.gpg" "$(env_value "$kernel_env" copr_key)"
    file=$(file_of "$(env_value "$kernel_env" srpm)")
    fetch "$COPR_RESULTS/$copr/$chroot/Packages/${file:0:1}/$file" "$dir/kernel/$file"
    verify_rpm "$dir/kernel/$file" "$(env_value "$kernel_env" srpm_sha256)" "$keyring_db"
    fetch "$NEGATIVO17_KEY_URL" "$dir/nvidia/${NEGATIVO17_KEY_URL##*/}"
    keyring "$dir/nvidia/${NEGATIVO17_KEY_URL##*/}" "$(env_value "$nvidia_env" negativo17_key)"
    while read -r nevra sha256 rest; do
        [[ -n $sha256 && -z $rest ]] || cannot "nvidia.env has a malformed line for $nevra"
        fetch "$(negativo17_url "$nevra")" "$dir/nvidia/$(file_of "$nevra")"
        verify_rpm "$dir/nvidia/$(file_of "$nevra")" "$sha256" "$keyring_db"
    done < <(printf '%s %s\n' "$(env_value "$nvidia_env" kmod_srpm)" "$(env_value "$nvidia_env" kmod_srpm_sha256)"
        sed -n 's/^userspace=//p' "$nvidia_env")
    for side in kernel nvidia; do
        for file in "$dir/$side"/*; do
            name=${file##*/}
            (cd -- "$dir/$side" && sha256sum -- "$name") >"$file.sha256"
        done
    done
    (cd -- "$dir" && find kernel nvidia -type f -printf '%p\0' | LC_ALL=C sort -z | xargs -0 sha256sum --) >"$dir/verified.partial"
    mv -- "$dir/verified.partial" "$dir/verified"
    printf 'ok both sides verified: %s files\n' "$(($(wc -l <"$dir/verified")))"
}

# Sets plan[SIDE] to "new", or to the files of DIR/SIDE the release lacks; refuses on a differing one.
compare_side() {
    local dir=$1 side=$2 tag=$3 existing name got file
    if ! existing=$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' 2>/dev/null); then
        plan[$side]=new
        return
    fi
    plan[$side]=
    got=$(mktemp -d)
    for file in "$dir/$side"/*; do
        name=${file##*/}
        if ! grep -qxF -- "$name" <<<"$existing"; then
            plan[$side]+="$name"$'\n'
            continue
        fi
        gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$name" --dir "$got" ||
            cannot "cannot download $name from $tag"
        if ! cmp -s -- "$got/$name" "$file"; then
            verdict refused "$name" "$tag holds different bytes"
            refuse "$tag holds a different $name"
        fi
        verdict present "$name" "$tag"
    done
}

publish() {
    local dir=$1 side tag name
    [[ -n ${GITHUB_REPOSITORY:-} ]] || cannot "GITHUB_REPOSITORY is not set"
    [[ -s $dir/verified ]] || refuse "$dir has no verified list: collect did not finish"
    (cd -- "$dir" && sha256sum --check --strict --quiet verified >/dev/null 2>&1) || refuse "$dir does not match its verified list"
    [[ $(sed -E 's/^[0-9a-f]{64}  //' "$dir/verified" | LC_ALL=C sort | paste -sd' ') == \
        "$(cd -- "$dir" && find kernel nvidia -type f -printf '%p\n' | LC_ALL=C sort | paste -sd' ')" ]] ||
        refuse "$dir holds files collect did not verify, or lacks some it did"
    [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || printf '| Asset | Release | Verdict |\n|---|---|---|\n' >>"$GITHUB_STEP_SUMMARY"
    local -A tags=([kernel]=$(kernel_tag) [nvidia]=$(nvidia_tag))
    declare -gA plan=()
    for side in kernel nvidia; do
        compare_side "$dir" "$side" "${tags[$side]}"
    done
    for side in kernel nvidia; do
        tag=${tags[$side]}
        local -a files=()
        if [[ ${plan[$side]} == new ]]; then
            files=("$dir/$side"/*)
            gh release create "$tag" --repo "$GITHUB_REPOSITORY" --title "$tag" --target "${GITHUB_SHA:-main}" \
                --notes "Pinned pair inputs, each verified against kernel.env and nvidia.env before upload. Assets are never replaced." \
                -- "${files[@]}" >/dev/null || cannot "cannot create the release $tag"
        else
            while read -r name; do [[ -z $name ]] || files+=("$dir/$side/$name"); done <<<"${plan[$side]}"
            ((${#files[@]} == 0)) ||
                gh release upload "$tag" --repo "$GITHUB_REPOSITORY" -- "${files[@]}" >/dev/null || cannot "cannot upload to $tag"
        fi
        for name in "${files[@]}"; do verdict added "${name##*/}" "$tag"; done
    done
}

main() {
    case ${1:-} in
        tags) (($# == 1)) || { usage >&2; exit 2; } ;;
        collect | publish) (($# == 2)) || { usage >&2; exit 2; } ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    local here tool
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    fedora=${FEDORA:-45}
    if [[ $fedora == 45 ]]; then
        kernel_env=$here/kernel.env nvidia_env=$here/nvidia.env
    else
        kernel_env=$here/fedora-$fedora/kernel.env nvidia_env=$here/fedora-$fedora/nvidia.env
    fi
    [[ -f $kernel_env && -f $nvidia_env ]] || cannot "no kernel.env and nvidia.env for Fedora $fedora"
    case $1 in
        tags) kernel_tag; nvidia_tag ;;
        collect)
            for tool in curl rpmkeys sha256sum; do command -v "$tool" >/dev/null || cannot "no $tool"; done
            [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || printf '| Asset | Check | Verdict |\n|---|---|---|\n' >>"$GITHUB_STEP_SUMMARY"
            collect "$2" ;;
        publish)
            for tool in gh sha256sum cmp; do command -v "$tool" >/dev/null || cannot "no $tool"; done
            publish "$2" ;;
    esac
}

main "$@"
