#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    cat <<'EOF'
usage: pair-inputs.sh tag
       pair-inputs.sh collect DIR
       GITHUB_REPOSITORY=OWNER/REPO pair-inputs.sh publish DIR

The pair's durable input mirror (owner-approved 2026-11-15): one GitHub release per
kernel.env and nvidia.env, named pair-inputs-<kernel SRPM NVR>-<kmod version-release>.

tag      prints that release name for the pins next to this script.
collect  downloads into the empty DIR, under their upstream names, the kernel SRPM, the
         kmod SRPM, every userspace RPM, the COPR's pubkey.gpg and negativo17's
         RPM-GPG-KEY-slaanesh, from the URLs apex-lane fetches them from. Each key must
         be exactly its pinned fingerprint, each RPM its pinned sha256 and signed by its
         pinned key alone. Only then does it write DIR/SHA256SUMS, of every file.
publish  creates the release from DIR, or, when the tag exists, adds the files it lacks.
         It refuses, uploading nothing, when DIR has no SHA256SUMS or does not match it,
         or when the release holds an asset DIR lacks or one that differs from DIR's.
         An asset is never replaced or deleted.

Exit 1 when an input fails its pin or the release differs; the reason is on the last
line. Exit 2 when the script cannot run.
EOF
}

readonly COPR_RESULTS=https://download.copr.fedorainfracloud.org/results
readonly NEGATIVO17_REPOS=https://negativo17.org/repos/nvidia
readonly NEGATIVO17_KEY_URL=https://negativo17.org/repos/RPM-GPG-KEY-slaanesh
readonly COPR_KEY_FILE=pubkey.gpg
readonly NEGATIVO17_KEY_FILE=RPM-GPG-KEY-slaanesh

cannot() { printf 'pair-inputs.sh cannot run: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'pair-inputs.sh: %s\n' "$*" >&2; exit 1; }

env_value() {
    local file=$1 key=$2 value
    value=$(sed -n "s/^$key=//p" "$file")
    [[ -n $value && $value != *$'\n'* ]] || cannot "${file##*/} has no single $key"
    printf '%s\n' "$value"
}

file_of() { printf '%s.rpm\n' "$(sed -E 's/-[0-9]+:/-/' <<<"$1")"; }
nvr_of() { sed -E -e 's/-[0-9]+:/-/' -e 's/\.[a-z0-9_]+$//' <<<"$1"; }

release_tag() {
    local kernel kmod
    kernel=$(nvr_of "$(env_value "$kernel_env" srpm)")
    kmod=$(env_value "$nvidia_env" kmod_srpm)
    [[ $kmod =~ ^nvidia-kmod-[0-9]+:([^-]+)-([^-.]+)\. ]] || cannot "nvidia.env's kmod_srpm is not an nvidia-kmod NEVRA: $kmod"
    printf 'pair-inputs-%s-%s-%s\n' "$kernel" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

fetch() {
    local url=$1 to=$2
    curl --fail --silent --show-error --location --retry 3 --output "$to" -- "$url" ||
        refuse "cannot download $url"
}

keyring() {
    local key_file=$1 pinned=$2 db
    db=$(mktemp -d)
    rpmkeys --dbpath "$db" --import "$key_file" 2>/dev/null || refuse "${key_file##*/} does not import"
    [[ $(rpmkeys --dbpath "$db" --list | awk '{print $1}') == "${pinned,,}" ]] ||
        refuse "${key_file##*/} is not exactly the pinned key $pinned"
    printf '%s\n' "$db"
}

verify_rpm() {
    local file=$1 sha256=$2 db=$3
    [[ $(sha256sum -- "$file" | awk '{print $1}') == "$sha256" ]] || refuse "${file##*/} does not have its pinned sha256"
    rpmkeys --dbpath "$db" -K -- "$file" 2>&1 | grep -q 'digests signatures OK$' ||
        refuse "${file##*/} is not signed by its pinned key"
}

negativo17_url() {
    local nevra=$1 dir=x86_64
    [[ $nevra != *.src ]] || dir=SRPMS
    printf '%s/fedora-%s/%s/%s\n' "$NEGATIVO17_REPOS" "$fedora" "$dir" "$(file_of "$nevra")"
}

collect() {
    local dir=$1 copr chroot srpm file copr_db negativo17_db nevra sha256 rest sums
    [[ -d $dir && -z $(ls -A -- "$dir") ]] || cannot "$dir is not an empty directory"
    copr=$(env_value "$kernel_env" copr)
    chroot=$(env_value "$kernel_env" chroot)
    fetch "$COPR_RESULTS/$copr/pubkey.gpg" "$dir/$COPR_KEY_FILE"
    fetch "$NEGATIVO17_KEY_URL" "$dir/$NEGATIVO17_KEY_FILE"
    copr_db=$(keyring "$dir/$COPR_KEY_FILE" "$(env_value "$kernel_env" copr_key)")
    negativo17_db=$(keyring "$dir/$NEGATIVO17_KEY_FILE" "$(env_value "$nvidia_env" negativo17_key)")
    srpm=$(env_value "$kernel_env" srpm)
    file=$(file_of "$srpm")
    fetch "$COPR_RESULTS/$copr/$chroot/Packages/${file:0:1}/$file" "$dir/$file"
    verify_rpm "$dir/$file" "$(env_value "$kernel_env" srpm_sha256)" "$copr_db"
    while read -r nevra sha256 rest; do
        [[ -n $sha256 && -z $rest ]] || cannot "nvidia.env has a malformed line for $nevra"
        fetch "$(negativo17_url "$nevra")" "$dir/$(file_of "$nevra")"
        verify_rpm "$dir/$(file_of "$nevra")" "$sha256" "$negativo17_db"
    done < <(printf '%s %s\n' "$(env_value "$nvidia_env" kmod_srpm)" "$(env_value "$nvidia_env" kmod_srpm_sha256)"
        sed -n 's/^userspace=//p' "$nvidia_env")
    sums=$(mktemp)
    (cd -- "$dir" && find . -maxdepth 1 -type f -printf '%P\0' | LC_ALL=C sort -z | xargs -0 sha256sum --) >"$sums"
    mv -- "$sums" "$dir/SHA256SUMS"
    printf 'ok %s inputs match their pins\n' "$(($(wc -l <"$dir/SHA256SUMS")))"
}

publish() {
    local dir=$1 tag existing name got
    [[ -n ${GITHUB_REPOSITORY:-} ]] || cannot "GITHUB_REPOSITORY is not set"
    [[ -s $dir/SHA256SUMS ]] || refuse "$dir has no SHA256SUMS: collect did not finish"
    (cd -- "$dir" && sha256sum --check --strict --quiet SHA256SUMS >/dev/null 2>&1) || refuse "$dir does not match its SHA256SUMS"
    [[ $(sed -E 's/^[0-9a-f]{64}  //' "$dir/SHA256SUMS" | LC_ALL=C sort | paste -sd' ') == \
        "$(find "$dir" -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | paste -sd' ')" ]] ||
        refuse "$dir holds files SHA256SUMS does not list, or lacks some it lists"
    tag=$(release_tag)
    local -a files=("$dir/SHA256SUMS")
    while read -r _ name; do files+=("$dir/$name"); done <"$dir/SHA256SUMS"
    if ! existing=$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' 2>/dev/null); then
        gh release create "$tag" --repo "$GITHUB_REPOSITORY" --title "$tag" --target "${GITHUB_SHA:-main}" \
            --notes "The pair's pinned inputs, each verified against kernel.env and nvidia.env before upload; SHA256SUMS lists them." \
            -- "${files[@]}" >/dev/null || cannot "cannot create the release $tag"
        printf 'ok created %s with %s assets\n' "$tag" "${#files[@]}"
        return
    fi
    local got_dir
    got_dir=$(mktemp -d)
    local -a missing=()
    while read -r name; do
        [[ -n $name ]] || continue
        [[ -f $dir/$name ]] || refuse "$tag holds $name, which these pins do not name"
        gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$name" --dir "$got_dir" ||
            cannot "cannot download $name from $tag"
        got=$(sha256sum -- "$got_dir/$name" | awk '{print $1}')
        [[ $got == "$(sha256sum -- "$dir/$name" | awk '{print $1}')" ]] || refuse "$tag holds a different $name"
    done <<<"$existing"
    for name in "${files[@]}"; do
        grep -qxF -- "${name##*/}" <<<"$existing" || missing+=("$name")
    done
    if ((${#missing[@]} == 0)); then
        printf 'ok %s already holds every input\n' "$tag"
        return
    fi
    gh release upload "$tag" --repo "$GITHUB_REPOSITORY" -- "${missing[@]}" >/dev/null || cannot "cannot upload to $tag"
    printf 'ok added %s missing assets to %s\n' "${#missing[@]}" "$tag"
}

main() {
    case ${1:-} in
        tag) (($# == 1)) || { usage >&2; exit 2; } ;;
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
        tag) release_tag ;;
        collect)
            for tool in curl rpmkeys sha256sum; do command -v "$tool" >/dev/null || cannot "no $tool"; done
            collect "$2" ;;
        publish)
            for tool in gh sha256sum; do command -v "$tool" >/dev/null || cannot "no $tool"; done
            publish "$2" ;;
    esac
}

main "$@"
