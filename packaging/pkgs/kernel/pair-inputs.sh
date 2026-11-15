#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later

set -euo pipefail

usage() {
    cat <<'EOF'
usage: pair-inputs.sh tags | releases | packages
       GITHUB_REPOSITORY=OWNER/REPO pair-inputs.sh collect DIR
       GITHUB_REPOSITORY=OWNER/REPO pair-inputs.sh publish DIR

The pair's durable input mirror (owner-approved 2026-11-15): one GitHub release per
side, so that a kernel can pair with an older driver.

  pair-inputs-kernel-<kernel SRPM NVR>            the kernel SRPM and the COPR's pubkey.gpg
  pair-inputs-nvidia-<kmod version>-<kmod release> the kmod SRPM, every userspace RPM and
                                                   negativo17's RPM-GPG-KEY-slaanesh

Each file is an asset under the basename of its upstream URL, with <basename>.sha256
beside it. A release only grows: nothing is replaced or deleted.

tags      prints the two release names for FEDORA's pins (45 when unset).
releases  prints 45 and each N of a fedora-N/ next to this script that holds both pins.
packages  prints the Fedora packages the job needs; pair-inputs.yml installs them.
collect   downloads both sides into DIR/kernel and DIR/nvidia, from the URLs apex-lane
          fetches them from. A file upstream answers with 404 or 410 is taken from its
          side's release instead. Each key must be exactly its pinned fingerprint, each
          RPM its pinned sha256 and signed by its pinned key alone. Only when every file
          of both sides passes does it write the .sha256 files and DIR/verified.
publish   for each side, compares every asset the release already holds under one of
          DIR's names, then uploads the ones it lacks and publishes a draft that an
          interrupted run left. A differing asset refuses the whole publish before
          anything is uploaded; a re-served key passes when the held one is still the
          pinned fingerprint.

Each file's verdict (verified, refused, present, added, published) goes to stdout and,
in Actions, to the job summary. Exit 1 when an input fails its pin or a release differs;
the reason is on the last line. Exit 2 when the script cannot run.
EOF
}

readonly COPR_RESULTS=https://download.copr.fedorainfracloud.org/results
readonly NEGATIVO17_REPOS=https://negativo17.org/repos/nvidia
readonly NEGATIVO17_KEY_URL=https://negativo17.org/repos/RPM-GPG-KEY-slaanesh
readonly COPR_KEY_FILE=pubkey.gpg
readonly NEGATIVO17_KEY_FILE=RPM-GPG-KEY-slaanesh
readonly PACKAGES="coreutils curl diffutils findutils gawk gh grep rpm sed"

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

# Downloads URL to TO; a 404 or 410 takes the file from release TAG instead.
fetch() {
    local url=$1 to=$2 tag=$3 code
    if ! code=$(curl --silent --show-error --location --retry 3 --output "$to" --write-out '%{http_code}' -- "$url"); then
        verdict refused "${to##*/}" "not downloaded"
        refuse "cannot download $url"
    fi
    case $code in
        200) ;;
        404 | 410)
            rm -f -- "$to"
            if ! gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "${to##*/}" --dir "${to%/*}" 2>/dev/null ||
                [[ ! -f $to ]]; then
                verdict refused "${to##*/}" "upstream $code, not in $tag"
                refuse "$url answers $code and $tag holds no ${to##*/}"
            fi
            from_release+=" ${to##*/}" ;;
        *)
            verdict refused "${to##*/}" "upstream $code"
            refuse "$url answers $code" ;;
    esac
}

source_of() { [[ " $from_release " == *" ${1##*/} "* ]] && printf ' (from its release)' || true; }

# Sets keyring_db to a keyring that holds KEY-FILE, which must be exactly PINNED.
keyring() {
    local key_file=$1 pinned=$2
    keyring_db=$(mktemp -d)
    if ! rpmkeys --dbpath "$keyring_db" --import "$key_file" 2>/dev/null ||
        [[ $(rpmkeys --dbpath "$keyring_db" --list | awk '{print $1}') != "${pinned,,}" ]]; then
        verdict refused "${key_file##*/}" "not the pinned key"
        refuse "${key_file##*/} is not exactly the pinned key $pinned"
    fi
    verdict verified "${key_file##*/}" "key $pinned$(source_of "$key_file")"
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
    verdict verified "${file##*/}" "sha256 and signature$(source_of "$file")"
}

negativo17_url() {
    local dir=x86_64
    [[ $1 != *.src ]] || dir=SRPMS
    printf '%s/fedora-%s/%s/%s\n' "$NEGATIVO17_REPOS" "$fedora" "$dir" "$(file_of "$1")"
}

collect() {
    local dir=$1 copr chroot file nevra sha256 rest side name ktag ntag
    [[ -d $dir && -z $(ls -A -- "$dir") ]] || cannot "$dir is not an empty directory"
    mkdir -- "$dir/kernel" "$dir/nvidia"
    ktag=$(kernel_tag) ntag=$(nvidia_tag) from_release=
    copr=$(env_value "$kernel_env" copr)
    chroot=$(env_value "$kernel_env" chroot)
    fetch "$COPR_RESULTS/$copr/pubkey.gpg" "$dir/kernel/$COPR_KEY_FILE" "$ktag"
    keyring "$dir/kernel/$COPR_KEY_FILE" "$(env_value "$kernel_env" copr_key)"
    file=$(file_of "$(env_value "$kernel_env" srpm)")
    fetch "$COPR_RESULTS/$copr/$chroot/Packages/${file:0:1}/$file" "$dir/kernel/$file" "$ktag"
    verify_rpm "$dir/kernel/$file" "$(env_value "$kernel_env" srpm_sha256)" "$keyring_db"
    fetch "$NEGATIVO17_KEY_URL" "$dir/nvidia/$NEGATIVO17_KEY_FILE" "$ntag"
    keyring "$dir/nvidia/$NEGATIVO17_KEY_FILE" "$(env_value "$nvidia_env" negativo17_key)"
    while read -r nevra sha256 rest; do
        [[ -n $sha256 && -z $rest ]] || cannot "nvidia.env has a malformed line for $nevra"
        fetch "$(negativo17_url "$nevra")" "$dir/nvidia/$(file_of "$nevra")" "$ntag"
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

# The release's key differs from upstream's: it passes if it is still exactly the pinned
# fingerprint and its held .sha256 matches it.
held_key_passes() {
    local tag=$1 key=$2 pinned=$3 got=$4 db
    gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$key" --dir "$got" --clobber 2>/dev/null &&
        gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$key.sha256" --dir "$got" --clobber 2>/dev/null ||
        return 1
    db=$(mktemp -d)
    rpmkeys --dbpath "$db" --import "$got/$key" 2>/dev/null &&
        [[ $(rpmkeys --dbpath "$db" --list | awk '{print $1}') == "${pinned,,}" ]] &&
        (cd -- "$got" && sha256sum --check --strict --quiet -- "$key.sha256" >/dev/null 2>&1)
}

# gh release view merges its tag and draft lookups, so a flaky draft lookup reads as
# not found; the REST list holds drafts too. Sets listed to "ID DRAFT" lines and assets.
list_release() {
    local tag=$1 out
    out=$(gh api --paginate "repos/$GITHUB_REPOSITORY/releases?per_page=100" \
        --jq ".[] | select(.tag_name == \"$tag\") | \"release \\(.id) \\(.draft)\", (.assets[] | \"asset \\(.state) \\(.name)\")" 2>&1) ||
        cannot "cannot list the releases of $GITHUB_REPOSITORY: $(tr '\n' ' ' <<<"$out")"
    listed=$(sed -n 's/^release //p' <<<"$out")
    assets=$(sed -n 's/^asset //p' <<<"$out")
}

# After a write, TAG must still name exactly one release, and ID when given.
one_release() {
    local tag=$1 id=${2:-}
    list_release "$tag"
    [[ $(grep -c . <<<"$listed") == 1 && ( -z $id || ${listed%% *} == "$id" ) ]] ||
        refuse "$tag names $(grep -c . <<<"$listed") releases after the write, not the one it wrote to"
}

# Sets plan[SIDE] to "new", or to the files of DIR/SIDE the release lacks, and draft[SIDE]
# and id[SIDE]; refuses on a differing asset, an unfinished upload or a tag of two releases.
compare_side() {
    local dir=$1 side=$2 tag=$3 key=$4 pinned=$5 existing name state got file
    list_release "$tag"
    case $(grep -c . <<<"$listed") in
        0) plan[$side]=new draft[$side]=false id[$side]= ; return ;;
        1) ;;
        *) verdict refused "$tag" "names $(grep -c . <<<"$listed") releases"
            refuse "$tag names $(grep -c . <<<"$listed") releases" ;;
    esac
    id[$side]=${listed%% *} draft[$side]=${listed##* }
    existing=$assets
    while read -r state name; do
        [[ -z $name || $state == uploaded ]] || {
            verdict refused "$name" "$tag holds it in state $state"
            refuse "$tag holds $name in state $state, an interrupted upload"
        }
    done <<<"$existing"
    existing=$(cut -d' ' -f2- <<<"$existing")
    plan[$side]=
    got=$(mktemp -d)
    for file in "$dir/$side"/*; do
        name=${file##*/}
        if ! grep -qxF -- "$name" <<<"$existing"; then
            plan[$side]+="$name"$'\n'
            continue
        fi
        gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$name" --dir "$got" --clobber ||
            cannot "cannot download $name from $tag"
        if cmp -s -- "$got/$name" "$file"; then
            verdict present "$name" "$tag"
        elif [[ $name == "$key" || $name == "$key.sha256" ]] && grep -qxF -- "$key.sha256" <<<"$existing" &&
            held_key_passes "$tag" "$key" "$pinned" "$got"; then
            verdict present "$name" "$tag (held key, same fingerprint)"
        else
            verdict refused "$name" "$tag holds different bytes"
            refuse "$tag holds a different $name"
        fi
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
    local -A keys=([kernel]=$COPR_KEY_FILE [nvidia]=$NEGATIVO17_KEY_FILE)
    local -A pins=([kernel]=$(env_value "$kernel_env" copr_key) [nvidia]=$(env_value "$nvidia_env" negativo17_key))
    declare -gA plan=() draft=() id=()
    for side in kernel nvidia; do
        compare_side "$dir" "$side" "${tags[$side]}" "${keys[$side]}" "${pins[$side]}"
    done
    for side in kernel nvidia; do
        tag=${tags[$side]}
        local -a files=()
        if [[ ${plan[$side]} == new ]]; then
            files=("$dir/$side"/*)
            gh release create "$tag" --repo "$GITHUB_REPOSITORY" --title "$tag" --target "${GITHUB_SHA:-main}" \
                --notes "Pinned pair inputs, each verified against kernel.env and nvidia.env before upload. Assets are never replaced." \
                -- "${files[@]}" >/dev/null || cannot "cannot create the release $tag"
            one_release "$tag"
        else
            while read -r name; do [[ -z $name ]] || files+=("$dir/$side/$name"); done <<<"${plan[$side]}"
            ((${#files[@]} == 0)) ||
                gh release upload "$tag" --repo "$GITHUB_REPOSITORY" -- "${files[@]}" >/dev/null || cannot "cannot upload to $tag"
            ((${#files[@]} == 0)) || one_release "$tag" "${id[$side]}"
        fi
        for name in "${files[@]}"; do verdict added "${name##*/}" "$tag"; done
        if [[ ${draft[$side]} == true ]]; then
            gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false >/dev/null || cannot "cannot publish the draft $tag"
            one_release "$tag" "${id[$side]}"
            [[ ${listed##* } == false ]] || refuse "$tag is still a draft after gh release edit"
            verdict published "$tag" "a draft an interrupted run left"
        fi
    done
}

releases() {
    local dir
    printf '45\n'
    for dir in "$here"/fedora-*/; do
        [[ -f $dir/kernel.env && -f $dir/nvidia.env ]] || continue
        dir=${dir%/}
        printf '%s\n' "${dir##*/fedora-}"
    done
}

main() {
    case ${1:-} in
        tags | releases | packages) (($# == 1)) || { usage >&2; exit 2; } ;;
        collect | publish) (($# == 2)) || { usage >&2; exit 2; } ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    local tool
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    case $1 in
        packages) printf '%s\n' "$PACKAGES"; return ;;
        releases) releases; return ;;
    esac
    fedora=${FEDORA:-45}
    if [[ $fedora == 45 ]]; then
        kernel_env=$here/kernel.env nvidia_env=$here/nvidia.env
    else
        kernel_env=$here/fedora-$fedora/kernel.env nvidia_env=$here/fedora-$fedora/nvidia.env
    fi
    [[ -f $kernel_env && -f $nvidia_env ]] || cannot "no kernel.env and nvidia.env for Fedora $fedora"
    [[ $1 == tags ]] || for tool in awk cmp curl find gh grep rpmkeys sed sha256sum; do
        command -v "$tool" >/dev/null || cannot "no $tool"
    done
    case $1 in
        tags) kernel_tag; nvidia_tag ;;
        collect)
            [[ -n ${GITHUB_REPOSITORY:-} ]] || cannot "GITHUB_REPOSITORY is not set"
            [[ -z ${GITHUB_STEP_SUMMARY:-} ]] || printf '| Asset | Check | Verdict |\n|---|---|---|\n' >>"$GITHUB_STEP_SUMMARY"
            collect "$2" ;;
        publish) publish "$2" ;;
    esac
}

main "$@"
