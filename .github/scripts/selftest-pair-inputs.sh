#!/usr/bin/env bash
# shellcheck disable=SC2154 # sourced by selftest-kernel.sh, which owns TMP and the check helpers
# SPDX-License-Identifier: GPL-3.0-or-later
# ci.yml also runs this file alone in pair-inputs.yml's container, with only that job's packages.

if [[ -z ${APEX_ROOT:-} ]]; then
    set -euo pipefail
    APEX_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    FAILS=0 TESTS=0 STANDALONE=1
    pass() { TESTS=$((TESTS + 1)); }
    flunk() { TESTS=$((TESTS + 1)) FAILS=$((FAILS + 1)); printf 'FAIL: %s\n' "$*" >&2; }
    check() { if [[ $2 == "$3" ]]; then pass; else flunk "$1: expected '$2', got '$3'"; fi; }
    check_true() {
        local name=$1
        shift
        if (set +e; "$@") >/dev/null 2>&1; then pass; else flunk "$name: expected success"; fi
    }
fi
KERNEL_SRC="$APEX_ROOT/packaging/pkgs/kernel"
COPR_FPR=537deed33436b0367f5b26d5b3e3132cf10859cf
NEGATIVO17_FPR=0c5d0f470484ae2fc40a9b6597f3008993e8909b
OTHER_FPR=1111111111111111111111111111111111111111

M="$TMP/pair-inputs"
mkdir -p "$M/bin" "$M/kernel" "$M/http" "$M/gh/releases" "$M/gh/drafts" "$M/gh/states" "$M/gh/dups"
cp "$KERNEL_SRC/pair-inputs.sh" "$M/kernel/"
cat >"$M/bin/rpmkeys" <<'EOF'
#!/usr/bin/env bash
db=$2
shift 2
case $1 in
    --import) sed -n 's/^fpr=//p' "$2" >>"$db/keys"; sed -n 's/^sub=//p' "$2" >>"$db/subs" ;;
    --list) sed 's/$/ fake key/' "$db/keys" ;;
    -K)
        file=${!#}
        if grep -qxF -- "$(sed -n 's/^signer=//p' "$file")" "$db/keys" "$db/subs" 2>/dev/null; then
            echo "$file: digests signatures OK"
        else
            echo "$file: digests SIGNATURES NOT OK"
            exit 1
        fi ;;
esac
EOF
cat >"$M/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
while (($# > 1)); do [[ $1 != --output ]] || out=$2; shift; done
file=$FAKE_HTTP/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
[[ ! -e $file.down ]] || { echo "fake curl: cannot connect to $1" >&2; exit 7; }
if [[ -f $file ]]; then cp "$file" "$out"; printf 200; else printf 'gone\n' >"$out"; cat "$file.code" 2>/dev/null || printf 404; fi
EOF
cat >"$M/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH/log"
asset_id() { cksum <<<"$1/$2" | cut -d' ' -f1; }
if [[ $1 == api && $2 == -X && $3 == DELETE ]]; then
    want=${4##*/}
    for f in "$FAKE_GH"/releases/*/*; do
        t=${f%/*}
        t=${t##*/}
        [[ $(asset_id "$t" "${f##*/}") == "$want" ]] || continue
        rm -f -- "$f" "$FAKE_GH/states/$t/${f##*/}"
        exit 0
    done
    echo "HTTP 404: Not Found" >&2
    exit 1
fi
if [[ $1 == api ]]; then
    [[ ! -e $FAKE_GH/fail-api ]] || { echo "HTTP 502: Bad Gateway (https://api.github.com/repos/x/releases)" >&2; exit 1; }
    tag=$(sed -n 's/.*tag_name == "\([^"]*\)".*/\1/p' <<<"$*")
    rel=$FAKE_GH/releases/$tag
    [[ -d $rel ]] || exit 0
    if [[ -e $FAKE_GH/drafts/$tag ]]; then draft=true; else draft=false; fi
    printf 'release %s %s\n' "$(cksum <<<"$tag" | cut -d' ' -f1)" "$draft"
    for f in "$rel"/*; do
        [[ -e $f ]] && printf 'asset %s %s %s\n' "$(cat "$FAKE_GH/states/$tag/${f##*/}" 2>/dev/null || echo uploaded)" \
            "$(asset_id "$tag" "${f##*/}")" "${f##*/}"
    done
    [[ ! -e $FAKE_GH/dups/$tag ]] || printf 'release 9999 false\n'
    exit 0
fi
cmd=$2 tag=$3 rel=$FAKE_GH/releases/$3
shift 3
if [[ -e $FAKE_GH/graphql-down && -e $FAKE_GH/drafts/$tag && $cmd != create ]]; then
    echo "release not found" >&2
    exit 1
fi
files=() pattern= dir=
while (($#)); do
    case $1 in
        --pattern) pattern=$2; shift 2 ;;
        --dir) dir=$2; shift 2 ;;
        --clobber | --draft=false) shift ;;
        --) shift; files+=("$@"); break ;;
        --*) shift 2 ;;
        *) files+=("$1"); shift ;;
    esac
done
case $cmd in
    create)
        [[ ! -d $rel ]] || exit 1
        mkdir -p "$rel"
        : >"$FAKE_GH/drafts/$tag"
        if [[ -n ${FAKE_GH_KILL_AFTER:-} ]]; then
            cp -- "${files[@]:0:$FAKE_GH_KILL_AFTER}" "$rel/"
            if [[ -n ${FAKE_GH_STUB:-} ]]; then
                stub=${files[$FAKE_GH_KILL_AFTER]}
                head -c 3 -- "$stub" >"$rel/${stub##*/}"
                mkdir -p "$FAKE_GH/states/$tag"
                echo starter >"$FAKE_GH/states/$tag/${stub##*/}"
            fi
            exit 137
        fi
        cp -- "${files[@]}" "$rel/"
        rm -f "$FAKE_GH/drafts/$tag" ;;
    upload)
        [[ ! -e $FAKE_GH/dup-on-write ]] || : >"$FAKE_GH/dups/$tag"
        for f in "${files[@]}"; do [[ ! -e $rel/${f##*/} ]] || { echo "asset ${f##*/} exists" >&2; exit 1; }; done
        cp -- "${files[@]}" "$rel/" ;;
    download) [[ ! -e $FAKE_GH/fail-download && $(cat "$FAKE_GH/fail-download-of" 2>/dev/null) != "$pattern" ]] ||
        { echo "HTTP 503: Service Unavailable" >&2; exit 1; }
        [[ -f $rel/$pattern ]] || { echo "no asset $pattern" >&2; exit 1; }; cp -- "$rel/$pattern" "$dir/" ;;
    edit) rm -f "$FAKE_GH/drafts/$tag" ;;
esac
EOF
chmod +x "$M/bin/rpmkeys" "$M/bin/curl" "$M/bin/gh"
key_of() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
serve() { cat >"$M/http/$(key_of "$1")"; }
fake_rpm() { printf 'signer=%s\nnevr=%s\n' "$1" "$2"; }
COPR=https://download.copr.fedorainfracloud.org/results/bieszczaders/kernel-cachyos
NEG=https://negativo17.org/repos/nvidia/fedora-45
COPR_KEY_URL=$COPR/pubkey.gpg
NEG_KEY_URL=https://negativo17.org/repos/RPM-GPG-KEY-slaanesh
serve "$COPR_KEY_URL" <<<"fpr=$COPR_FPR"
serve "$NEG_KEY_URL" <<<"fpr=$NEGATIVO17_FPR"
pin_file() { # URL SIGNER NEVR: serves a fake RPM and prints its sha256
    fake_rpm "$2" "$3" | serve "$1"
    sha256sum <"$M/http/$(key_of "$1")" | cut -d' ' -f1
}
K_SUM=$(pin_file "$COPR/fedora-45-x86_64/Packages/k/kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm" "$COPR_FPR" kernel-cachyos-0:7.3.0-4.cachyos1.fc45.src)
N_SUM=$(pin_file "$NEG/SRPMS/nvidia-kmod-620.70.06-1.fc45.src.rpm" "$NEGATIVO17_FPR" nvidia-kmod-3:620.70.06-1.fc45.src)
D_SUM=$(pin_file "$NEG/x86_64/nvidia-driver-620.70.06-1.fc45.x86_64.rpm" "$NEGATIVO17_FPR" nvidia-driver-3:620.70.06-1.fc45.x86_64)
S_SUM=$(pin_file "$NEG/x86_64/nvidia-driver-selinux-0.1-3.fc45.noarch.rpm" "$NEGATIVO17_FPR" nvidia-driver-selinux-0:0.1-3.fc45.noarch)
cat >"$M/kernel/kernel.env" <<EOF
copr=bieszczaders/kernel-cachyos
chroot=fedora-45-x86_64
srpm=kernel-cachyos-0:7.3.0-4.cachyos1.fc45.src
srpm_sha256=$K_SUM
copr_key=${COPR_FPR^^}
EOF
cat >"$M/kernel/nvidia.env" <<EOF
kmod_srpm=nvidia-kmod-3:620.70.06-1.fc45.src
kmod_srpm_sha256=$N_SUM
userspace=nvidia-driver-3:620.70.06-1.fc45.x86_64 $D_SUM
userspace=nvidia-driver-selinux-0:0.1-3.fc45.noarch $S_SUM
negativo17_key=${NEGATIVO17_FPR^^}
EOF
KTAG=pair-inputs-kernel-kernel-cachyos-7.3.0-4.cachyos1.fc45
NTAG=pair-inputs-nvidia-620.70.06-1.fc45
KMOD=nvidia-kmod-620.70.06-1.fc45.src.rpm
KMOD_URL=$NEG/SRPMS/$KMOD
inputs() { # COMMAND DIR [VAR=VALUE...]: pair-inputs.sh's exit, its output in $M/out, the summary in $M/summary
    local rc=0 cmd=$1 dir=$2
    shift 2
    : >"$M/summary"
    env PATH="$M/bin:$PATH" FAKE_HTTP="$M/http" FAKE_GH="$M/gh" GITHUB_REPOSITORY=apex-linux/apex-kernel GITHUB_SHA=abc \
        GITHUB_STEP_SUMMARY="$M/summary" "$@" "$M/kernel/pair-inputs.sh" "$cmd" "$dir" >"$M/out" 2>&1 || rc=$?
    printf '%s' "$rc"
}
fresh() { rm -rf "${M:?}/${1:?}" && mkdir "$M/$1"; }
collected() { fresh "$1" && [[ $(inputs collect "$M/$1") == 0 ]]; }
gh_writes() { grep -cE '^release (create|upload|edit) ' "$M/gh/log" || true; }
release_files() { find "$M/gh/releases/$1" -type f -printf '%P\n' | LC_ALL=C sort | paste -sd' '; }
last() { tail -n 1 "$M/out"; }
KFILES="kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm.sha256 pubkey.gpg pubkey.gpg.sha256"
NFILES="RPM-GPG-KEY-slaanesh RPM-GPG-KEY-slaanesh.sha256 nvidia-driver-620.70.06-1.fc45.x86_64.rpm nvidia-driver-620.70.06-1.fc45.x86_64.rpm.sha256 nvidia-driver-selinux-0.1-3.fc45.noarch.rpm nvidia-driver-selinux-0.1-3.fc45.noarch.rpm.sha256 nvidia-kmod-620.70.06-1.fc45.src.rpm nvidia-kmod-620.70.06-1.fc45.src.rpm.sha256"

# --- names, releases and the job's packages ---------------------------------------------
check "pair-inputs: the tags, byte for byte as apex-lane derives them" \
    "pair-inputs-kernel-kernel-cachyos-7.3.0-4.cachyos1.fc45
pair-inputs-nvidia-620.70.06-1.fc45" "$("$M/kernel/pair-inputs.sh" tags)"
check "pair-inputs: the real pins' tags" \
    "pair-inputs-kernel-$(sed -n 's/^srpm=\(.*\)-[0-9]*:\(.*\)\.src$/\1-\2/p' "$KERNEL_SRC/kernel.env")
pair-inputs-nvidia-$(sed -n 's/^kmod_srpm=nvidia-kmod-[0-9]*:\(.*\)\.src$/\1/p' "$KERNEL_SRC/nvidia.env")" \
    "$("$KERNEL_SRC/pair-inputs.sh" tags)"
check "pair-inputs: releases is 45 alone without a fedora-N/" 45 "$("$M/kernel/pair-inputs.sh" releases)"
mkdir -p "$M/kernel/fedora-46" "$M/kernel/fedora-47"
: >"$M/kernel/fedora-46/kernel.env"
: >"$M/kernel/fedora-46/nvidia.env"
check "pair-inputs: and names a fedora-N/ that holds both pins" "45 46" "$("$M/kernel/pair-inputs.sh" releases | paste -sd' ')"
rm -r "$M/kernel/fedora-46" "$M/kernel/fedora-47"
check_true "pair-inputs: the job's packages hold cmp's" grep -qw diffutils <<<"$("$M/kernel/pair-inputs.sh" packages)"
for tool in awk cmp curl find gh grep rpmkeys sed sha256sum; do
    check_true "pair-inputs: $tool is checked before it is needed" grep -q " ${tool}[ ;]" <<<"$(grep 'for tool in' "$KERNEL_SRC/pair-inputs.sh")"
done

if [[ -n ${STANDALONE:-} ]]; then
    check "pair-inputs: every tool main() checks for is on the real PATH, the faked ones too" "" \
        "$(read -ra tools <<<"$(sed -n 's/.*for tool in \(.*\); do$/\1/p' "$KERNEL_SRC/pair-inputs.sh")"
            for tool in "${tools[@]}"; do command -v "$tool" >/dev/null || printf '%s ' "$tool"; done)"
fi
check "pair-inputs: every tool it needs and nothing fakes is installed" "" \
    "$(for tool in awk cmp find grep sed sha256sum; do command -v "$tool" >/dev/null || printf '%s ' "$tool"; done)"

# --- verify, then publish; releases only grow ---------------------------------------------
check_true "pair-inputs: collect runs" collected ok
check "pair-inputs: every pinned input of both sides verifies" "6" "$(grep -c '| verified |$' "$M/summary")"
check "pair-inputs: each file has a .sha256 of its own, holding its pinned sum" "$K_SUM $N_SUM $D_SUM $S_SUM" \
    "$(cut -d' ' -f1 "$M/ok/kernel/kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm.sha256" "$M/ok/nvidia/$KMOD.sha256" \
        "$M/ok/nvidia/nvidia-driver-620.70.06-1.fc45.x86_64.rpm.sha256" "$M/ok/nvidia/nvidia-driver-selinux-0.1-3.fc45.noarch.rpm.sha256" | paste -sd' ')"
check "pair-inputs: and checks with sha256sum beside its file" ok "$(cd "$M/ok/nvidia" && sha256sum --check --quiet "$KMOD.sha256" && echo ok)"
check "pair-inputs: new tags are created per side" 0 "$(inputs publish "$M/ok")"
check "pair-inputs: the kernel release holds the SRPM and pubkey.gpg" "$KFILES" "$(release_files "$KTAG")"
check "pair-inputs: the driver release holds the kmod, the userspace and the key" "$NFILES" "$(release_files "$NTAG")"
check "pair-inputs: one write each, nothing left a draft" "2 0" "$(gh_writes) $(find "$M/gh/drafts" -type f | wc -l)"
check "pair-inputs: each asset reported as added" 12 "$(grep -c '| added |$' "$M/summary")"
check "pair-inputs: publishing again writes nothing" "0 2 12" "$(inputs publish "$M/ok") $(gh_writes) $(grep -c '| present |$' "$M/summary")"

rm "$M/gh/releases/$NTAG/nvidia-driver-620.70.06-1.fc45.x86_64.rpm"
check "pair-inputs: a release lacking an asset gets it added" 0 "$(inputs publish "$M/ok")"
check "pair-inputs: that one alone" "release upload $NTAG --repo apex-linux/apex-kernel -- $M/ok/nvidia/nvidia-driver-620.70.06-1.fc45.x86_64.rpm" \
    "$(grep '^release upload ' "$M/gh/log" | tail -n 1)"

D2_SUM=$(pin_file "$NEG/x86_64/nvidia-driver-620.70.06-2.fc45.x86_64.rpm" "$NEGATIVO17_FPR" nvidia-driver-3:620.70.06-2.fc45.x86_64)
sed -i "s/^userspace=nvidia-driver-3:.*/userspace=nvidia-driver-3:620.70.06-2.fc45.x86_64 $D2_SUM/" "$M/kernel/nvidia.env"
: >"$M/gh/log"
check_true "pair-inputs: a userspace rebuild under the same kmod verifies" collected grow
check "pair-inputs: and grows the driver release" 0 "$(inputs publish "$M/grow")"
check "pair-inputs: by its new file and .sha256 alone" \
    "release upload $NTAG --repo apex-linux/apex-kernel -- $M/grow/nvidia/nvidia-driver-620.70.06-2.fc45.x86_64.rpm $M/grow/nvidia/nvidia-driver-620.70.06-2.fc45.x86_64.rpm.sha256" \
    "$(grep -E '^release (create|upload|edit) ' "$M/gh/log")"
check "pair-inputs: keeping the older build" "nvidia-driver-620.70.06-1.fc45.x86_64.rpm nvidia-driver-620.70.06-2.fc45.x86_64.rpm" \
    "$(release_files "$NTAG" | tr ' ' '\n' | grep '^nvidia-driver-620.*rpm$' | paste -sd' ')"
sed -i "s/^userspace=nvidia-driver-3:.*/userspace=nvidia-driver-3:620.70.06-1.fc45.x86_64 $D_SUM/" "$M/kernel/nvidia.env"

# --- a differing asset refuses the whole publish ------------------------------------------
: >"$M/gh/log"
cp "$M/gh/releases/$KTAG/kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm" "$M/held.keep"
printf 'x' >>"$M/gh/releases/$KTAG/kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm"
rm "$M/gh/releases/$NTAG/RPM-GPG-KEY-slaanesh.sha256"
check "pair-inputs: a release with a differing RPM is refused" 1 "$(inputs publish "$M/ok")"
check "pair-inputs: naming it" "pair-inputs.sh: $KTAG holds a different kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm" "$(last)"
check "pair-inputs: in the job summary" 1 "$(grep -c "| $KTAG holds different bytes | refused |$" "$M/summary")"
check "pair-inputs: and nothing is uploaded on either side" 0 "$(gh_writes)"
cp "$M/held.keep" "$M/gh/releases/$KTAG/kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm"
check "pair-inputs: once it matches again, the missing one is added" "0 1" "$(inputs publish "$M/ok") $(gh_writes)"
: >"$M/gh/log"
rm "$M/gh/releases/$KTAG/pubkey.gpg.sha256"
cp "$M/gh/releases/$NTAG/$KMOD" "$M/held.keep"
printf 'x' >>"$M/gh/releases/$NTAG/$KMOD"
check "pair-inputs: a driver release that differs refuses the kernel side's addition too" "1 0" "$(inputs publish "$M/ok") $(gh_writes)"
check "pair-inputs: naming the driver asset" "pair-inputs.sh: $NTAG holds a different $KMOD" "$(last)"
cp "$M/held.keep" "$M/gh/releases/$NTAG/$KMOD"
check "pair-inputs: then adds it once both sides match" "0 1" "$(inputs publish "$M/ok") $(gh_writes)"
: >"$M/gh/log"
printf 'x' >>"$M/gh/releases/$NTAG/$KMOD.sha256"
check "pair-inputs: a differing held .sha256 is refused" "1 0" "$(inputs publish "$M/ok") $(gh_writes)"
check "pair-inputs: naming it" "pair-inputs.sh: $NTAG holds a different $KMOD.sha256" "$(last)"
rm "$M/gh/releases/$NTAG/$KMOD.sha256"
check "pair-inputs: and added once it is gone" "0 1" "$(inputs publish "$M/ok") $(gh_writes)"

# --- a re-served key with the pinned fingerprint ------------------------------------------
printf 'fpr=%s\n# re-armored, expiry extended\n' "$COPR_FPR" | serve "$COPR_KEY_URL"
: >"$M/gh/log"
check_true "pair-inputs: a re-served COPR key with the pinned fingerprint verifies" collected rekey
check "pair-inputs: the held key still passes, so nothing is uploaded" "0 0" "$(inputs publish "$M/rekey") $(gh_writes)"
check "pair-inputs: reported as the held key" 2 "$(grep -c "| $KTAG (held key, same fingerprint) | present |$" "$M/summary")"
cp "$M/gh/releases/$KTAG/pubkey.gpg" "$M/held.keep"
printf 'fpr=%s\n' "$OTHER_FPR" >"$M/gh/releases/$KTAG/pubkey.gpg"
(cd "$M/gh/releases/$KTAG" && sha256sum pubkey.gpg >pubkey.gpg.sha256)
check "pair-inputs: a held key that is not the pinned one is refused" "1 0" "$(inputs publish "$M/rekey") $(gh_writes)"
check "pair-inputs: naming it" "pair-inputs.sh: $KTAG holds a different pubkey.gpg" "$(last)"
cp "$M/held.keep" "$M/gh/releases/$KTAG/pubkey.gpg"
check "pair-inputs: a held key whose .sha256 does not match it is refused" "1 0" "$(inputs publish "$M/rekey") $(gh_writes)"
(cd "$M/gh/releases/$KTAG" && sha256sum pubkey.gpg >pubkey.gpg.sha256)
serve "$COPR_KEY_URL" <<<"fpr=$COPR_FPR"

# --- drafts an interrupted run left, unfinished uploads and unreadable releases ----------
K2_SUM=$(pin_file "$COPR/fedora-45-x86_64/Packages/k/kernel-cachyos-7.3.1-1.cachyos1.fc45.src.rpm" "$COPR_FPR" kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src)
sed -i "s/^srpm=.*/srpm=kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src/; s/^srpm_sha256=.*/srpm_sha256=$K2_SUM/" "$M/kernel/kernel.env"
K2TAG=pair-inputs-kernel-kernel-cachyos-7.3.1-1.cachyos1.fc45
check_true "pair-inputs: a newer kernel verifies" collected k2
: >"$M/gh/log"
check "pair-inputs: a create killed during its upload fails the run" 2 "$(inputs publish "$M/k2" FAKE_GH_KILL_AFTER=1)"
check "pair-inputs: and leaves a draft holding part of it" "1 1" "$(find "$M/gh/drafts" -name "$K2TAG" | wc -l) $(find "$M/gh/releases/$K2TAG" -type f | wc -l)"
: >"$M/gh/graphql-down"
: >"$M/gh/log"
check "pair-inputs: with gh's draft lookup down, the re-run stops" 2 "$(inputs publish "$M/k2")"
check "pair-inputs: and creates no second release beside the draft" "0 1" \
    "$(grep -c '^release create ' "$M/gh/log") $(PATH="$M/bin:$PATH" FAKE_GH="$M/gh" gh api --paginate "repos/x/releases" --jq "select(.tag_name == \"$K2TAG\")" | grep -c '^release ')"
rm "$M/gh/graphql-down"
check "pair-inputs: the re-run finishes it" 0 "$(inputs publish "$M/k2")"
check "pair-inputs: and publishes the draft" 0 "$(find "$M/gh/drafts" -name "$K2TAG" | wc -l)"
check "pair-inputs: saying so in the summary" 1 "$(grep -c "^| $K2TAG | a draft an interrupted run left | published |$" "$M/summary")"
check "pair-inputs: whole" "kernel-cachyos-7.3.1-1.cachyos1.fc45.src.rpm kernel-cachyos-7.3.1-1.cachyos1.fc45.src.rpm.sha256 pubkey.gpg pubkey.gpg.sha256" "$(release_files "$K2TAG")"
mkdir -p "$M/gh/states/$K2TAG"
printf 'starter\n' >"$M/gh/states/$K2TAG/pubkey.gpg"
: >"$M/gh/log"
check "pair-inputs: an asset an upload never finished is refused" "1 0" "$(inputs publish "$M/k2") $(gh_writes)"
check "pair-inputs: naming its state" "pair-inputs.sh: $K2TAG holds pubkey.gpg in state starter, an interrupted upload" "$(last)"
rm -r "$M/gh/states/$K2TAG"
: >"$M/gh/fail-api"
: >"$M/gh/log"
check "pair-inputs: a release list gh cannot read stops the run" "2 0" "$(inputs publish "$M/k2") $(gh_writes)"
check_true "pair-inputs: naming the error" grep -q "^pair-inputs.sh cannot run: cannot list the releases of apex-linux/apex-kernel: HTTP 502" "$M/out"
rm "$M/gh/fail-api"
: >"$M/gh/dups/$K2TAG"
check "pair-inputs: a tag that names two releases is refused" "1 0" "$(inputs publish "$M/k2") $(gh_writes)"
check "pair-inputs: naming the count" "pair-inputs.sh: $K2TAG names 2 releases" "$(last)"
rm "$M/gh/dups/$K2TAG"
rm "$M/gh/releases/$K2TAG/pubkey.gpg.sha256"
: >"$M/gh/dup-on-write"
check "pair-inputs: a write that leaves the tag naming two releases is refused" 1 "$(inputs publish "$M/k2")"
check "pair-inputs: after the write" "pair-inputs.sh: $K2TAG names 2 releases after the write, not the one it wrote to" "$(last)"
rm "$M/gh/dup-on-write" "$M/gh/dups/$K2TAG"

# --- collect: a file upstream dropped comes from its release ------------------------------
mv "$M/http/$(key_of "$KMOD_URL")" "$M/kmod.keep"
check "pair-inputs: a kmod upstream answers 404 for comes from its release" 0 "$(fresh drop && inputs collect "$M/drop")"
check "pair-inputs: verified there like any input" 1 "$(grep -c "^| $KMOD | sha256 and signature (from its release) | verified |$" "$M/summary")"
printf 410 >"$M/http/$(key_of "$KMOD_URL").code"
check "pair-inputs: a 410 too" 0 "$(fresh drop && inputs collect "$M/drop")"
printf 502 >"$M/http/$(key_of "$KMOD_URL").code"
check "pair-inputs: a 502 does not fall back" 1 "$(fresh drop && inputs collect "$M/drop")"
check "pair-inputs: naming the status" "pair-inputs.sh: $KMOD_URL answers 502" "$(last)"
rm "$M/http/$(key_of "$KMOD_URL").code"
mv "$M/gh/releases/$NTAG/$KMOD" "$M/held.keep"
check "pair-inputs: gone upstream and from its release is refused" 1 "$(fresh drop && inputs collect "$M/drop")"
check "pair-inputs: naming both" "pair-inputs.sh: $KMOD_URL answers 404 and $NTAG holds no $KMOD" "$(last)"
fake_rpm "$NEGATIVO17_FPR" other >"$M/gh/releases/$NTAG/$KMOD"
check "pair-inputs: a release copy that is not the pin is refused" 1 "$(fresh drop && inputs collect "$M/drop")"
check "pair-inputs: by its sha256" "pair-inputs.sh: $KMOD does not have its pinned sha256" "$(last)"
mv "$M/held.keep" "$M/gh/releases/$NTAG/$KMOD"
mv "$M/kmod.keep" "$M/http/$(key_of "$KMOD_URL")"
: >"$M/http/$(key_of "$KMOD_URL").down"
check "pair-inputs: an upstream it cannot reach is refused" 1 "$(fresh drop && inputs collect "$M/drop")"
rm "$M/http/$(key_of "$KMOD_URL").down"

# --- a create killed mid-upload, and gh errors in the fallback ------------------------------
K3_SUM=$(pin_file "$COPR/fedora-45-x86_64/Packages/k/kernel-cachyos-7.3.2-1.cachyos1.fc45.src.rpm" "$COPR_FPR" kernel-cachyos-0:7.3.2-1.cachyos1.fc45.src)
sed -i "s/^srpm=.*/srpm=kernel-cachyos-0:7.3.2-1.cachyos1.fc45.src/; s/^srpm_sha256=.*/srpm_sha256=$K3_SUM/" "$M/kernel/kernel.env"
K3TAG=pair-inputs-kernel-kernel-cachyos-7.3.2-1.cachyos1.fc45
check_true "pair-inputs: another kernel verifies" collected k3
check "pair-inputs: a create killed during an upload" 2 "$(inputs publish "$M/k3" FAKE_GH_KILL_AFTER=1 FAKE_GH_STUB=1)"
check "pair-inputs: leaves a draft with an unfinished asset" "starter" "$(cat "$M/gh/states/$K3TAG"/* | paste -sd' ')"
: >"$M/gh/log"
check "pair-inputs: the re-run finishes it" 0 "$(inputs publish "$M/k3")"
check "pair-inputs: deleting the draft's unfinished asset, its one delete" "1 1" \
    "$(grep -c '^api -X DELETE ' "$M/gh/log") $(grep -c "| an unfinished upload in the draft $K3TAG | deleted |$" "$M/summary")"
check "pair-inputs: uploading that file whole, and publishing" "0 ok" \
    "$(find "$M/gh/drafts" -name "$K3TAG" | wc -l) $(cmp -s "$M/gh/releases/$K3TAG/kernel-cachyos-7.3.2-1.cachyos1.fc45.src.rpm.sha256" "$M/k3/kernel/kernel-cachyos-7.3.2-1.cachyos1.fc45.src.rpm.sha256" && cmp -s "$M/gh/releases/$K3TAG/kernel-cachyos-7.3.2-1.cachyos1.fc45.src.rpm" "$M/k3/kernel/kernel-cachyos-7.3.2-1.cachyos1.fc45.src.rpm" && echo ok)"
check "pair-inputs: whole" "kernel-cachyos-7.3.2-1.cachyos1.fc45.src.rpm kernel-cachyos-7.3.2-1.cachyos1.fc45.src.rpm.sha256 pubkey.gpg pubkey.gpg.sha256" "$(release_files "$K3TAG")"

mv "$M/http/$(key_of "$KMOD_URL")" "$M/kmod.keep"
: >"$M/gh/fail-api"
check "pair-inputs: a fallback whose release list fails cannot run" 2 "$(fresh drop && inputs collect "$M/drop")"
check_true "pair-inputs: naming the gh error" grep -q "cannot list the releases of apex-linux/apex-kernel: HTTP 502" "$M/out"
rm "$M/gh/fail-api"
: >"$M/gh/fail-download"
check "pair-inputs: a fallback whose download fails cannot run" 2 "$(fresh drop && inputs collect "$M/drop")"
check "pair-inputs: naming it" "pair-inputs.sh cannot run: cannot download $KMOD from $NTAG: HTTP 503: Service Unavailable " "$(last)"
rm "$M/gh/fail-download"
mkdir -p "$M/gh/states/$NTAG"
echo starter >"$M/gh/states/$NTAG/$KMOD"
check "pair-inputs: a release copy that never finished uploading is not taken" 1 "$(fresh drop && inputs collect "$M/drop")"
check "pair-inputs: naming both" "pair-inputs.sh: $KMOD_URL answers 404 and $NTAG holds no $KMOD" "$(last)"
rm -r "$M/gh/states/$NTAG"
mv "$M/kmod.keep" "$M/http/$(key_of "$KMOD_URL")"

# --- a re-served key must still verify what it is added beside ----------------------------
NEWSUB=2222222222222222222222222222222222222222
D3_URL=$NEG/x86_64/nvidia-driver-620.70.06-3.fc45.x86_64.rpm
printf 'fpr=%s\nsub=%s\n' "$NEGATIVO17_FPR" "$NEWSUB" | serve "$NEG_KEY_URL"
D3_SUM=$(pin_file "$D3_URL" "$NEWSUB" nvidia-driver-3:620.70.06-3.fc45.x86_64)
sed -i "s/^userspace=nvidia-driver-3:.*/userspace=nvidia-driver-3:620.70.06-3.fc45.x86_64 $D3_SUM/" "$M/kernel/nvidia.env"
check_true "pair-inputs: a key re-served with a new subkey verifies an RPM it signed" collected sub
: >"$M/gh/log"
check "pair-inputs: but the held key without that subkey refuses adding it" "1 0" "$(inputs publish "$M/sub") $(gh_writes)"
check "pair-inputs: naming the RPM" "pair-inputs.sh: $NTAG holds an older RPM-GPG-KEY-slaanesh that does not verify nvidia-driver-620.70.06-3.fc45.x86_64.rpm" "$(last)"
D3_SUM=$(pin_file "$D3_URL" "$NEGATIVO17_FPR" nvidia-driver-3:620.70.06-3.fc45.x86_64)
sed -i "s/^userspace=nvidia-driver-3:.*/userspace=nvidia-driver-3:620.70.06-3.fc45.x86_64 $D3_SUM/" "$M/kernel/nvidia.env"
check_true "pair-inputs: one signed by the primary key" collected sub
check "pair-inputs: is added beside the held key" "0 1" "$(inputs publish "$M/sub") $(gh_writes)"
echo RPM-GPG-KEY-slaanesh.sha256 >"$M/gh/fail-download-of"
: >"$M/gh/log"
check "pair-inputs: a held key's .sha256 gh cannot download stops the run, not a refusal" "2 0" "$(inputs publish "$M/sub") $(gh_writes)"
check "pair-inputs: naming the gh error" "pair-inputs.sh cannot run: cannot download RPM-GPG-KEY-slaanesh.sha256 from $NTAG: HTTP 503: Service Unavailable " "$(last)"
rm "$M/gh/fail-download-of"
serve "$NEG_KEY_URL" <<<"fpr=$NEGATIVO17_FPR"
sed -i "s/^userspace=nvidia-driver-3:.*/userspace=nvidia-driver-3:620.70.06-1.fc45.x86_64 $D_SUM/" "$M/kernel/nvidia.env"

# --- collect refuses what is not the pin --------------------------------------------------
wrong() { # NAME URL CONTENT-COMMAND EXPECTED-REASON: collect refuses a served input
    cp "$M/http/$(key_of "$2")" "$M/keep"
    eval "$3" | serve "$2"
    fresh bad
    check "pair-inputs: $1 is refused" 1 "$(inputs collect "$M/bad")"
    check "pair-inputs: $1, the reason" "pair-inputs.sh: $4" "$(last)"
    check "pair-inputs: $1, in the summary" 1 "$(grep -c '| refused |$' "$M/summary")"
    check "pair-inputs: $1, so nothing to publish" "1 pair-inputs.sh: $M/bad has no verified list: collect did not finish" \
        "$(inputs publish "$M/bad") $(last)"
    serve "$2" <"$M/keep"
}
wrong "an RPM with another sha256" "$KMOD_URL" "fake_rpm $NEGATIVO17_FPR other" "$KMOD does not have its pinned sha256"
sed -i "s/^kmod_srpm_sha256=.*/kmod_srpm_sha256=$(fake_rpm "$OTHER_FPR" nvidia-kmod-3:620.70.06-1.fc45.src | sha256sum | cut -d' ' -f1)/" "$M/kernel/nvidia.env"
wrong "an RPM signed by another key" "$KMOD_URL" "fake_rpm $OTHER_FPR nvidia-kmod-3:620.70.06-1.fc45.src" "$KMOD is not signed by its pinned key"
sed -i "s/^kmod_srpm_sha256=.*/kmod_srpm_sha256=$N_SUM/" "$M/kernel/nvidia.env"
wrong "a key file that is not the pinned key" "$NEG_KEY_URL" "echo fpr=$OTHER_FPR" \
    "RPM-GPG-KEY-slaanesh is not exactly the pinned key ${NEGATIVO17_FPR^^}"
wrong "a key file holding the pinned key and another" "$NEG_KEY_URL" "printf 'fpr=%s\nfpr=%s\n' $NEGATIVO17_FPR $OTHER_FPR" \
    "RPM-GPG-KEY-slaanesh is not exactly the pinned key ${NEGATIVO17_FPR^^}"
check "pair-inputs: collect wants an empty directory" 2 "$(inputs collect "$M/ok")"

if [[ -n ${STANDALONE:-} ]]; then
    ((FAILS == 0)) || { printf 'selftest-pair-inputs: %s failure(s)\n' "$FAILS" >&2; exit 1; }
    printf 'selftest-pair-inputs: all %s checks passed\n' "$TESTS"
fi
