#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
shopt -s inherit_errexit

usage() {
    cat <<'EOF'
usage: bump.sh check
       bump.sh nvidia-env

Compares kernel.env and nvidia.env with what the COPR, kernel.org and negativo17
offer now, and never edits either file. First the kernel, in one or two lines:

  point NEVRA                                  a newer build of the pinned major
  major NEVRA waiting-for-owner EOL-in-Nd      a newer major; N counts the days until
                                               the pinned major's estimated EOL
  none

When both exist, the point line comes first: the lane takes it unattended, and the
major line keeps the owner's countdown in view. A build counts
when its chroot (kernel.env's chroot) succeeded, whatever the whole build's state.
The pinned major's EOL is 0 days once kernel.org lists it as EOL or no longer lists
it, and otherwise 16 days after the next major's release ("unknown" when that date
is not in releases.json). Then one line per package of nvidia.env:

  nvidia NEVRA SHA256 pinned|older             the newest build of the pinned branch
  nvidia NEVRA SHA256 newer soaked|soaking-Nd  a newer one, built at least soak_days
                                               ago (nvidia.env, 7 if absent), or N
                                               more days to go
  nvidia NAME missing                          no build of the pinned branch

nvidia-env prints, on stdout, the nvidia.env that pins the newest soaked build of the
pinned branch for every package, the other lines kept as they are. It refuses, with
exit 1 and the reason on the last line, while a package is missing, still soaking,
older than its pin, or of another driver version than the kmod.

Exit 2 when a source cannot be read. BUMP_NOW (seconds since the epoch) replaces
the clock.
EOF
}

readonly COPR_API=https://copr.fedorainfracloud.org/api_3
readonly RELEASES_JSON=https://www.kernel.org/releases.json
readonly NEGATIVO17_REPOS=https://negativo17.org/repos/nvidia
readonly BUILD_LIST_LIMIT=30
readonly EOL_DAYS_AFTER_NEXT_MAJOR=16
readonly SECONDS_PER_DAY=86400
readonly DEFAULT_SOAK_DAYS=7

cannot() { printf 'bump.sh cannot run: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'bump.sh: %s\n' "$*" >&2; exit 1; }

fetch() {
    curl --fail --silent --show-error --location --retry 3 -- "$1" || cannot "cannot read $1"
}

env_value() {
    local file=$1 key=$2 value
    value=$(sed -n "s/^$key=//p" "$file")
    [[ -n $value && $value != *$'\n'* ]] || cannot "${file##*/} has no single $key"
    printf '%s\n' "$value"
}

major_of() { cut -d. -f1,2 <<<"$1"; }

newer_major() {
    [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]
}

chroot_succeeded() {
    local id=$1 state
    state=$(fetch "$COPR_API/build-chroot?build_id=$id&chrootname=$chroot" | jq -r '.state') ||
        cannot "the COPR's build-chroot answer for $id is not JSON"
    [[ $state == succeeded ]]
}

eol_in() {
    local pinned_major=$1 next_major=$2 releases listed released days
    releases=$(fetch "$RELEASES_JSON")
    listed=$(jq -r --arg m "$pinned_major" \
        '[.releases[] | select(.version == $m or (.version | startswith($m + "."))) | .iseol] | if length == 0 then "gone" elif all then "eol" else "live" end' \
        <<<"$releases") || cannot "releases.json is not JSON"
    if [[ $listed != live ]]; then
        printf 'EOL-in-0d\n'
        return
    fi
    released=$(jq -r --arg m "$next_major" \
        'first(.releases[] | select(.moniker == "mainline" and .version == $m) | .released.timestamp) // empty' <<<"$releases")
    if [[ -z $released ]]; then
        printf 'EOL-in-unknown\n'
        return
    fi
    days=$(((released + EOL_DAYS_AFTER_NEXT_MAJOR * SECONDS_PER_DAY - now + SECONDS_PER_DAY - 1) / SECONDS_PER_DAY))
    printf 'EOL-in-%dd\n' "$((days > 0 ? days : 0))"
}

check_kernel() {
    local srpm name pinned dist copr builds pinned_id id version major point='' major_bump=''
    srpm=$(env_value "$kernel_env" srpm)
    copr=$(env_value "$kernel_env" copr)
    [[ $srpm =~ ^(.+)-0:([^-]+-[^-]+)\.(fc[0-9]+)\.src$ ]] || cannot "kernel.env's srpm is not an fc SRPM NEVRA"
    name=${BASH_REMATCH[1]} pinned=${BASH_REMATCH[2]} dist=${BASH_REMATCH[3]}
    builds=$(fetch "$COPR_API/build/list/?ownername=${copr%/*}&projectname=${copr#*/}&packagename=$name&limit=$BUILD_LIST_LIMIT" |
        jq -r '.items[] | select(.source_package.version != null) | "\(.id) \(.source_package.version)"') ||
        cannot "the COPR's build list is not JSON"
    pinned_id=$(awk -v v="$pinned" '$2 == v { print $1 }' <<<"$builds" | sort -n | tail -n 1)
    [[ -n $pinned_id ]] || cannot "the pinned $pinned is not among the COPR's $BUILD_LIST_LIMIT newest builds"
    while read -r id version; do
        ((id > pinned_id)) || continue
        major=$(major_of "$version")
        if [[ $major == "$(major_of "$pinned")" ]]; then
            [[ -n $point ]] || { chroot_succeeded "$id" && point=$version; } || true
        elif newer_major "$major" "$(major_of "$pinned")"; then
            [[ -n $major_bump ]] || { chroot_succeeded "$id" && major_bump=$version; } || true
        fi
    done < <(sort -rn <<<"$builds")
    [[ -z $point ]] || printf 'point %s-0:%s.%s.src\n' "$name" "$point" "$dist"
    [[ -z $major_bump ]] || printf 'major %s-0:%s.%s.src waiting-for-owner %s\n' "$name" "$major_bump" "$dist" \
        "$(eol_in "$(major_of "$pinned")" "$(major_of "$major_bump")")"
    [[ -n $point || -n $major_bump ]] || printf 'none\n'
}

# Each package of primary.xml as "name arch epoch ver rel sha256".
packages_of() {
    local repo=$1 primary
    primary=$(fetch "$repo/repodata/repomd.xml" |
        awk '/<data type="primary">/ { p = 1 } p && /<location href=/ { sub(/.*href="/, ""); sub(/".*/, ""); print; exit }')
    [[ -n $primary ]] || cannot "$repo/repodata/repomd.xml names no primary"
    fetch "$repo/$primary" | gzip -dc | awk '
        function attr(n) { return match($0, n "=\"[^\"]*\"") ? substr($0, RSTART + length(n) + 2, RLENGTH - length(n) - 3) : "" }
        /<package / { name = arch = epoch = ver = rel = sum = "" }
        /<name>/ { name = $0; gsub(/.*<name>|<\/name>.*/, "", name) }
        /<arch>/ { arch = $0; gsub(/.*<arch>|<\/arch>.*/, "", arch) }
        /<version / { epoch = attr("epoch"); ver = attr("ver"); rel = attr("rel") }
        /<checksum type="sha256"/ { sum = $0; gsub(/.*">|<\/checksum>.*/, "", sum) }
        /<time / { built = attr("build") }
        /<\/package>/ { print name, arch, epoch, ver, rel, sum, built }' || cannot "$repo/$primary does not unpack"
}

soak_days() {
    local days
    days=$(sed -n 's/^soak_days=//p' "$nvidia_env")
    days=${days:-$DEFAULT_SOAK_DAYS}
    [[ $days =~ ^[1-9][0-9]*$ ]] || cannot "nvidia.env's soak_days is a number of days, not '$days'"
    printf '%s\n' "$days"
}

# One line per pinned package: "pin NAME NEVRA SHA256 STATUS [SOAK]" or "pin NAME missing".
nvidia_builds() {
    local release nevra name version rel arch branch newest status soak days built newest_vr newest_epoch newest_sum
    release=$(sed -E 's/^(fedora-[0-9]+)-.*/\1/' <<<"$chroot")
    days=$(soak_days)
    local -A seen=()
    local available
    available=$(packages_of "$NEGATIVO17_REPOS/$release/SRPMS"; packages_of "$NEGATIVO17_REPOS/$release/x86_64")
    while read -r nevra; do
        [[ $nevra =~ ^(.+)-([0-9]+):([^-]+)-([^-]+)\.([a-z0-9_]+)$ ]] || cannot "nvidia.env has a malformed NEVRA: $nevra"
        name=${BASH_REMATCH[1]} version=${BASH_REMATCH[3]} rel=${BASH_REMATCH[4]} arch=${BASH_REMATCH[5]}
        [[ -z ${seen[$name.$arch]:-} ]] || continue
        seen[$name.$arch]=1
        branch=${version%%.*}
        newest=$(awk -v n="$name" -v a="$arch" -v b="$branch" '$1 == n && $2 == a && index($4, b ".") == 1 || $1 == n && $2 == a && $4 == b { print $4 "-" $5, $3, $6, $7 }' \
            <<<"$available" | sort -V -k1,1 | tail -n 1)
        if [[ -z $newest ]]; then
            printf 'pin %s missing\n' "$name"
            continue
        fi
        read -r newest_vr newest_epoch newest_sum built <<<"$newest"
        soak=''
        if [[ $newest_vr == "$version-$rel" ]]; then
            status=pinned
        elif [[ $(printf '%s\n%s\n' "$newest_vr" "$version-$rel" | sort -V | tail -n 1) == "$newest_vr" ]]; then
            status=newer
            [[ $built =~ ^[0-9]+$ ]] || cannot "the repodata gives $name $newest_vr no build time"
            if ((now - built >= days * SECONDS_PER_DAY)); then
                soak=soaked
            else
                soak=soaking-$(((built + days * SECONDS_PER_DAY - now + SECONDS_PER_DAY - 1) / SECONDS_PER_DAY))d
            fi
        else
            status=older
        fi
        printf 'pin %s %s-%s:%s.%s %s %s%s\n' "$name" "$name" "$newest_epoch" "$newest_vr" "$arch" "$newest_sum" "$status" "${soak:+ $soak}"
    done < <(sed -n 's/^kmod_srpm=//p' "$nvidia_env"; sed -n 's/^userspace=\([^ ]*\) .*/\1/p' "$nvidia_env")
}

check_nvidia() {
    local builds
    builds=$(nvidia_builds)
    sed -E 's/^pin ([^ ]+) missing$/nvidia \1 missing/; t; s/^pin [^ ]+ /nvidia /' <<<"$builds"
}

driver_version() { sed -n 's/^[^:]*-[0-9]*:\([^-]*\)-.*/\1/p' <<<"$1"; }

nvidia_env() {
    local builds name nevra sum status soak rest kmod_nevra kmod_sum line
    builds=$(nvidia_builds)
    local -A pick=()
    while read -r _ name nevra sum status soak rest; do
        [[ $nevra != missing ]] || refuse "$name has no build of the pinned branch"
        [[ $status != older ]] || refuse "the newest build of $name, $nevra, is older than its pin"
        [[ $status != newer || $soak == soaked ]] || refuse "$nevra is still ${soak#soaking-} from soaked"
        pick[$name]="$nevra $sum"
    done <<<"$builds"
    read -r kmod_nevra kmod_sum <<<"${pick[nvidia-kmod]:-}"
    [[ -n $kmod_nevra ]] || refuse "nvidia.env pins no nvidia-kmod"
    for name in "${!pick[@]}"; do
        nevra=${pick[$name]%% *}
        [[ $nevra != *-3:* || $(driver_version "$nevra") == "$(driver_version "$kmod_nevra")" ]] ||
            refuse "$nevra is not driver $(driver_version "$kmod_nevra"), the kmod's"
    done
    while IFS= read -r line; do
        case $line in
            kmod_srpm=*) printf 'kmod_srpm=%s\n' "$kmod_nevra" ;;
            kmod_srpm_sha256=*) printf 'kmod_srpm_sha256=%s\n' "$kmod_sum" ;;
            userspace=*)
                nevra=${line#userspace=}
                nevra=${nevra%% *}
                printf 'userspace=%s\n' "${pick[${nevra%-[0-9]*:*}]}" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <"$nvidia_env"
}

main() {
    case ${1:-} in
        check | nvidia-env) (($# == 1)) || { usage >&2; exit 2; } ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
    local tool
    for tool in curl jq gzip awk sort; do
        command -v "$tool" >/dev/null || cannot "no $tool"
    done
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    kernel_env=$here/kernel.env nvidia_env=$here/nvidia.env
    chroot=$(env_value "$kernel_env" chroot)
    now=${BUMP_NOW:-$(date +%s)}
    if [[ $1 == nvidia-env ]]; then
        nvidia_env
    else
        check_kernel
        check_nvidia
    fi
}

main "$@"
