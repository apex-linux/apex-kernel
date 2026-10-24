# shellcheck shell=bash disable=SC2154 # sourced by selftest.sh, which owns TMP, APEX_ROOT and the check helpers
# SPDX-License-Identifier: GPL-3.0-or-later

KERNEL_SRC="$APEX_ROOT/packaging/pkgs/kernel"
SHM=$(mktemp -d -p /dev/shm apex-selftest.XXXXXX)
trap 'rm -rf "$TMP" "$SHM"' EXIT
COPR_FPR=537deed33436b0367f5b26d5b3e3132cf10859cf
NEGATIVO17_FPR=0c5d0f470484ae2fc40a9b6597f3008993e8909b
OTHER_FPR=1111111111111111111111111111111111111111

fake() {
    local name=$1
    cat >"$P/bin/$name"
    chmod +x "$P/bin/$name"
}

fake_rpm_file() {
    local file=$1 signer=$2 nevr=$3
    printf 'signer=%s\nnevr=%s\n' "$signer" "$nevr" >"$file"
}

sha_of() { sha256sum -- "$1" | awk '{print $1}'; }

# --- pair.sh: against fake rpm tools, a fake kmod build and a fake check.sh ------------
P="$TMP/pair"
mkdir -p "$P/bin" "$P/mirror"
cp -r "$KERNEL_SRC" "$P/kernel"
sed -n '/^@@/,${/^@@/d; /^+/d; s/^[ -]//; p}' "$KERNEL_SRC/kernel-spec.patch" >"$P/kernel-cachyos.spec"

fake rpmkeys <<'EOF'
#!/usr/bin/env bash
db=$2
shift 2
case $1 in
    --import) sed -n 's/^fpr=//p' "$2" >>"$db/keys" ;;
    --list) sed 's/$/ fake key/' "$db/keys" ;;
    -K)
        file=${!#}
        if grep -qxF -- "$(sed -n 's/^signer=//p' "$file")" "$db/keys"; then
            echo "$file: digests signatures OK"
        else
            echo "$file: digests SIGNATURES NOT OK"
            exit 1
        fi ;;
esac
EOF
fake rpm <<'EOF'
#!/usr/bin/env bash
if [[ $1 == --query ]]; then sed -n 's/^nevr=//p' "${!#}"; exit; fi
args=("$@")
for ((i = 0; i < $#; i++)); do
    [[ ${args[i]} == --define && ${args[i + 1]} == "_topdir "* ]] && topdir=${args[i + 1]#_topdir }
done
mkdir -p "$topdir/SPECS"
cp "$FAKE_SPEC" "$topdir/SPECS/kernel-cachyos.spec"
EOF
fake rpmbuild <<'EOF'
#!/usr/bin/env bash
args=("$@")
for ((i = 0; i < $#; i++)); do
    [[ ${args[i]} == --define && ${args[i + 1]} == "_topdir "* ]] && topdir=${args[i + 1]#_topdir }
    [[ ${args[i]} == --define && ${args[i + 1]} == "apex_module_sig_key "* ]] && key=${args[i + 1]#apex_module_sig_key }
done
grep -q apex_module_sig_key "${!#}" || { echo "the spec is not patched"; exit 1; }
[[ -s $key ]] || { echo "no module key at $key"; exit 1; }
((${FAKE_RPMBUILD_RC:-0} == 0)) || { echo "fake rpmbuild failure"; exit "$FAKE_RPMBUILD_RC"; }
[[ " $* " == *" --noclean "* ]] || { echo "rpmbuild would remove the build tree"; exit 1; }
tree=$topdir/BUILD/kernel-cachyos-7.3.0-build/linux-cachyos-7.3.0-4
mkdir -p "$tree"
printf 'fake vmlinux%s\n' "${FAKE_VMLINUX_NOTE:-}" >"$tree/vmlinux"
printf 'fake System.map\n' >"$tree/System.map"
printf 'CONFIG_FAKE=y\n' >"$tree/.config"
echo "fake rpmbuild log"
mkdir -p "$topdir/RPMS/x86_64"
for name in kernel-cachyos kernel-cachyos-core kernel-cachyos-modules kernel-cachyos-devel; do
    printf 'nevr=%s-0:7.3.0-4.cachyos1.fc45.x86_64\n' "$name" >"$topdir/RPMS/x86_64/$name-7.3.0-4.cachyos1.fc45.x86_64.rpm"
done
EOF
fake dnf5 <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
fake readelf <<'EOF'
#!/usr/bin/env bash
! grep -q 'not an ELF' "${!#}" || { echo "readelf: Error: Failed to read file's magic number" >&2; exit 1; }
printf '  [ 1] .text             PROGBITS\n'
grep -q 'without BTF' "${!#}" || printf '  [14] .BTF              PROGBITS\n  [15] .BTF_ids          PROGBITS\n'
EOF
cat >"$P/kernel/kmod-build.sh" <<'EOF'
#!/usr/bin/env bash
[[ -s $3/signing_key.pem ]] || { echo "no module key"; exit 1; }
touch "${FAKE_SCOPE_LOG%/*}/kmod-build-ran"
printf 'nevr=kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64-3:615.78.08-1.fc45.x86_64\n' \
    >"$4/RPMS/x86_64/kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64-615.78.08-1.fc45.x86_64.rpm"
((${FAKE_KMOD_RC:-0} == 0)) || { echo "fake kmod failure after a partial RPM"; exit "$FAKE_KMOD_RC"; }
EOF
cat >"$P/kernel/check.sh" <<'EOF'
#!/usr/bin/env bash
[[ -s $MODULE_CERT ]] || { echo "not ok: no certificate" >&2; exit 2; }
printf '%s\n' "${CHECK_SCOPE:-unset}" >>"$FAKE_SCOPE_LOG"
[[ ! -e ${MODULE_CERT%/*}/signing_key.pem ]] || { echo "not ok: the private key is still there" >&2; exit 1; }
((${FAKE_CHECK_RC:-0} == 0)) || { echo "not ok: fake check failure" >&2; exit "$FAKE_CHECK_RC"; }
echo ok
EOF
chmod +x "$P/kernel/kmod-build.sh" "$P/kernel/check.sh"

KERNEL_SRPM=kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm
KMOD_SRPM=nvidia-kmod-615.78.08-1.fc45.src.rpm
USERSPACE=nvidia-driver-615.78.08-1.fc45.x86_64.rpm
printf 'fpr=%s\n' "$COPR_FPR" >"$P/mirror/copr.gpg"
printf 'fpr=%s\n' "$NEGATIVO17_FPR" >"$P/mirror/negativo17.gpg"
fake_rpm_file "$P/mirror/$KERNEL_SRPM" "$COPR_FPR" kernel-cachyos-0:7.3.0-4.cachyos1.fc45.src
fake_rpm_file "$P/mirror/$KMOD_SRPM" "$NEGATIVO17_FPR" nvidia-kmod-3:615.78.08-1.fc45.src
fake_rpm_file "$P/mirror/$USERSPACE" "$NEGATIVO17_FPR" nvidia-driver-3:615.78.08-1.fc45.x86_64
cat >"$P/kernel/kernel.env" <<EOF
srpm=kernel-cachyos-0:7.3.0-4.cachyos1.fc45.src
srpm_sha256=$(sha_of "$P/mirror/$KERNEL_SRPM")
copr_key=${COPR_FPR^^}
EOF
cat >"$P/kernel/nvidia.env" <<EOF
kmod_srpm=nvidia-kmod-3:615.78.08-1.fc45.src
kmod_srpm_sha256=$(sha_of "$P/mirror/$KMOD_SRPM")
userspace=nvidia-driver-3:615.78.08-1.fc45.x86_64 $(sha_of "$P/mirror/$USERSPACE")
negativo17_key=${NEGATIVO17_FPR^^}
EOF

run_pair() {
    PAIR_KEY=$(mktemp -d -p "$SHM")
    PAIR_OUT=$(mktemp -d -p "$P")
    PAIR_RC=0
    mkdir "$PAIR_OUT/tmp"
    env PATH="$P/bin:$PATH" TMPDIR="$PAIR_OUT/tmp" FAKE_SCOPE_LOG="$PAIR_OUT/scope" FAKE_SPEC="$P/kernel-cachyos.spec" MODKEY_DIR="$PAIR_KEY" PAIR_ID=selftest "$@" \
        "$P/kernel/pair.sh" "$P/mirror" "$PAIR_OUT" --repo=fedora >"$PAIR_OUT/stdout" 2>"$PAIR_OUT/stderr" || PAIR_RC=$?
    PAIR_LAST=$(tail -n 1 "$PAIR_OUT/stderr")
}

shredded() { [[ ! -e $PAIR_KEY/signing_key.pem && -s $PAIR_KEY/signing_key.x509 ]]; }

run_pair
check "pair: a good pair exits 0" 0 "$PAIR_RC"
check "pair.lock names the kernel" kernel-cachyos-0:7.3.0-4.cachyos1.fc45.x86_64 \
    "$(sed -n 's/^kernel=//p' "$PAIR_OUT/pair.lock")"
check "pair.lock names the kmod" kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64-3:615.78.08-1.fc45.x86_64 \
    "$(sed -n 's/^kmod=//p' "$PAIR_OUT/pair.lock")"
check "pair.lock holds the module certificate's fingerprint" "$(sha_of "$PAIR_KEY/signing_key.x509")" \
    "$(sed -n 's/^module_cert_sha256=//p' "$PAIR_OUT/pair.lock")"
check "pair.lock holds every RPM's sha256" 5 "$(grep -cE '^rpm=[^ ]+\.rpm [0-9a-f]{64}$' "$PAIR_OUT/pair.lock")"
check_true "pair: the key is shredded after a good pair" shredded
check "pair: a good pair checks the whole pair" pair "$(cat "$PAIR_OUT/scope")"
check_false "pair: a good pair writes no kernel.lock" test -e "$PAIR_OUT/kernel.lock"
check_true "pair: a good pair runs the kmod build" test -e "$PAIR_OUT/kmod-build-ran"
check "pair: OUT/debug keeps vmlinux from the build tree" "fake vmlinux" "$(cat "$PAIR_OUT/debug/vmlinux")"
check "pair: OUT/debug keeps System.map" "fake System.map" "$(cat "$PAIR_OUT/debug/System.map")"
check "pair: OUT/debug keeps the kernel config" CONFIG_FAKE=y "$(cat "$PAIR_OUT/debug/config")"
check "pair: OUT/debug keeps the kernel build log" "fake rpmbuild log" "$(cat "$PAIR_OUT/debug/kernel.log")"
check_false "pair: the kept files are only under OUT/debug" test -e "$PAIR_OUT/vmlinux" -o -e "$PAIR_OUT/kernel.log"
check "pair: the build tree is gone after the copy" "" "$(find "$PAIR_OUT/tmp" -name vmlinux)"

run_pair "FAKE_VMLINUX_NOTE= without BTF"
check "pair: a vmlinux without .BTF holds the pair" 1 "$PAIR_RC"
check "pair: the missing BTF is named" "kernel: vmlinux has no .BTF section" "$PAIR_LAST"
check_false "pair: a vmlinux without .BTF writes no lock" test -e "$PAIR_OUT/pair.lock" -o -e "$PAIR_OUT/kernel.lock"
check_true "pair: a vmlinux without .BTF still keeps OUT/debug" test -s "$PAIR_OUT/debug/vmlinux"
check_true "pair: the key is shredded after a vmlinux without .BTF" shredded

run_pair "FAKE_VMLINUX_NOTE= not an ELF"
check "pair: an unreadable vmlinux holds the pair" 1 "$PAIR_RC"
check "pair: the unreadable vmlinux is named" "kernel: readelf cannot read vmlinux" "$PAIR_LAST"

run_pair FAKE_KMOD_RC=1
check "pair: a kmod failure holds the pair" 1 "$PAIR_RC"
check_true "pair: a kmod failure's reason starts with kmod:" grep -q '^kmod: ' <<<"$PAIR_LAST"
check_true "pair: the key is shredded after a kmod failure" shredded
check_false "pair: a kmod failure writes no pair.lock" test -e "$PAIR_OUT/pair.lock"
check "pair: a kmod failure checks the kernel alone" kernel "$(cat "$PAIR_OUT/scope")"
check "kernel.lock names the kernel" kernel-cachyos-0:7.3.0-4.cachyos1.fc45.x86_64 \
    "$(sed -n 's/^kernel=//p' "$PAIR_OUT/kernel.lock")"
check_false "kernel.lock has no kmod line" grep -q '^kmod=' "$PAIR_OUT/kernel.lock"
check_false "kernel.lock names no kmod RPM" grep -q 'kmod-nvidia' "$PAIR_OUT/kernel.lock"
check "kernel.lock holds the module certificate's fingerprint" "$(sha_of "$PAIR_KEY/signing_key.x509")" \
    "$(sed -n 's/^module_cert_sha256=//p' "$PAIR_OUT/kernel.lock")"
check "kernel.lock holds the four kernel RPMs" 4 "$(grep -cE '^rpm=kernel-cachyos[^ ]*\.rpm [0-9a-f]{64}$' "$PAIR_OUT/kernel.lock")"
check "pair: a kmod failure copies the kernel RPMs alone" 4 "$(find "$PAIR_OUT/rpms" -name 'kernel-cachyos*.rpm' | wc -l)"
check_false "pair: a kmod failure copies no kmod RPM" test -n "$(find "$PAIR_OUT/rpms" -name 'kmod-nvidia*')"
check_true "pair: a kmod failure keeps vmlinux, System.map, config and the log" \
    test -s "$PAIR_OUT/debug/vmlinux" -a -s "$PAIR_OUT/debug/System.map" -a -s "$PAIR_OUT/debug/config" -a -s "$PAIR_OUT/debug/kernel.log"

run_pair APEX_PAIR_FAULT=kmod
check "pair: APEX_PAIR_FAULT=kmod holds the pair as a kmod failure" 1 "$PAIR_RC"
check "pair: the injected fault gives the kmod failure's reason" \
    "kmod: nvidia-kmod-3:615.78.08-1.fc45.src does not build for this kernel" "$PAIR_LAST"
check_false "pair: the injected fault runs no kmod build" test -e "$PAIR_OUT/kmod-build-ran"
check_true "pair: the injected fault still writes kernel.lock" test -s "$PAIR_OUT/kernel.lock"
check "pair: the injected fault checks the kernel alone" kernel "$(cat "$PAIR_OUT/scope")"
check_true "pair: the key is shredded after the injected fault" shredded

run_pair APEX_PAIR_FAULT=
check "pair: an empty APEX_PAIR_FAULT changes nothing" 0 "$PAIR_RC"
check_true "pair: an empty APEX_PAIR_FAULT runs the kmod build" test -e "$PAIR_OUT/kmod-build-ran"

run_pair APEX_PAIR_FAULT=kernel
check "pair: any other APEX_PAIR_FAULT means it cannot run" 2 "$PAIR_RC"
check "pair: the refused fault is named" "pair.sh cannot run: APEX_PAIR_FAULT is kmod or empty, not 'kernel'" "$PAIR_LAST"
check_false "pair: a refused fault makes no key" test -e "$PAIR_KEY/signing_key.x509"

run_pair FAKE_KMOD_RC=1 FAKE_CHECK_RC=1
check "pair: a kmod failure with a failed kernel check holds the pair" 1 "$PAIR_RC"
check "pair: the failed kernel check is the reason" "check: not ok: fake check failure" "$PAIR_LAST"
check_false "pair: a failed kernel check writes no kernel.lock" test -e "$PAIR_OUT/kernel.lock"
check_true "pair: the key is shredded after a kmod and a kernel check failure" shredded

run_pair FAKE_RPMBUILD_RC=1
check "pair: a kernel failure holds the pair" 1 "$PAIR_RC"
check_true "pair: a kernel failure's reason starts with kernel:" grep -q '^kernel: ' <<<"$PAIR_LAST"
check_true "pair: the key is shredded after a kernel failure" shredded
check_false "pair: a kernel failure writes no kernel.lock" test -e "$PAIR_OUT/kernel.lock"
check_false "pair: a kernel failure keeps no vmlinux" test -e "$PAIR_OUT/debug/vmlinux"
check_true "pair: a kernel failure keeps its log" test -s "$PAIR_OUT/debug/kernel.log"

run_pair FAKE_CHECK_RC=1
check "pair: a failed check holds the pair" 1 "$PAIR_RC"
check "pair: a failed check gives check.sh's reason" "check: not ok: fake check failure" "$PAIR_LAST"
check_true "pair: the key is shredded after a failed check" shredded

cp "$P/mirror/$KMOD_SRPM" "$P/good.rpm"
printf 'x\n' >>"$P/mirror/$KMOD_SRPM"
run_pair
check "pair: a mismatched sha256 holds the pair" 1 "$PAIR_RC"
check "pair: the mismatch is named" "$KMOD_SRPM does not have its pinned sha256" "$PAIR_LAST"
check_false "pair: no key is made for an unverified input" test -e "$PAIR_KEY/signing_key.x509"
mv "$P/good.rpm" "$P/mirror/$KMOD_SRPM"

cp "$P/mirror/negativo17.gpg" "$P/good.gpg"
printf 'fpr=%s\n' "$OTHER_FPR" >"$P/mirror/negativo17.gpg"
run_pair
check "pair: an unpinned key holds the pair" 1 "$PAIR_RC"
check_true "pair: the unpinned key is named" grep -q 'negativo17 key file is not exactly the pinned key' <<<"$PAIR_LAST"
printf 'fpr=%s\nfpr=%s\n' "$NEGATIVO17_FPR" "$OTHER_FPR" >"$P/mirror/negativo17.gpg"
run_pair
check "pair: a key file with an extra key holds the pair" 1 "$PAIR_RC"
mv "$P/good.gpg" "$P/mirror/negativo17.gpg"

cp "$P/mirror/$USERSPACE" "$P/good.rpm"
fake_rpm_file "$P/mirror/$USERSPACE" "$OTHER_FPR" nvidia-driver-3:615.78.08-1.fc45.x86_64
sed -i "s/^userspace=\([^ ]*\) .*/userspace=\1 $(sha_of "$P/mirror/$USERSPACE")/" "$P/kernel/nvidia.env"
run_pair
check "pair: an RPM signed by an unpinned key holds the pair" 1 "$PAIR_RC"
check "pair: the unpinned signature is named" "$USERSPACE is not signed by its pinned key" "$PAIR_LAST"
mv "$P/good.rpm" "$P/mirror/$USERSPACE"
sed -i "s/^userspace=\([^ ]*\) .*/userspace=\1 $(sha_of "$P/mirror/$USERSPACE")/" "$P/kernel/nvidia.env"

mv "$P/mirror/$USERSPACE" "$P/good.rpm"
run_pair
check "pair: a missing input means it cannot run" 2 "$PAIR_RC"
mv "$P/good.rpm" "$P/mirror/$USERSPACE"

PAIR_KEY_BUSY=$(mktemp -d -p "$SHM")
printf 'not ours\n' >"$PAIR_KEY_BUSY/signing_key.pem"
PAIR_OUT=$(mktemp -d -p "$P")
check "pair: a key directory in use means it cannot run" 2 \
    "$(rc_of env PATH="$P/bin:$PATH" FAKE_SPEC="$P/kernel-cachyos.spec" MODKEY_DIR="$PAIR_KEY_BUSY" \
        "$P/kernel/pair.sh" "$P/mirror" "$PAIR_OUT")"
check "pair: a key it did not make is left alone" "not ours" "$(cat "$PAIR_KEY_BUSY/signing_key.pem")"

# --- bump.sh: against canned COPR, kernel.org and negativo17 answers -------------------
B="$TMP/bump"
mkdir -p "$B/bin" "$B/kernel" "$B/http"
cp "$KERNEL_SRC/bump.sh" "$B/kernel/"
cat >"$B/bin/curl" <<'EOF'
#!/usr/bin/env bash
file=$FAKE_HTTP/$(printf '%s' "${!#}" | tr -c 'A-Za-z0-9._-' '_')
[[ -f $file ]] || { echo "fake curl: nothing at ${!#}" >&2; exit 22; }
cat "$file"
EOF
chmod +x "$B/bin/curl"
http() { cat >"$B/http/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
COPR_API=https://copr.fedorainfracloud.org/api_3
NEG=https://negativo17.org/repos/nvidia/fedora-45
cat >"$B/kernel/kernel.env" <<'EOF'
copr=bieszczaders/kernel-cachyos
chroot=fedora-45-x86_64
srpm=kernel-cachyos-0:7.3.0-4.cachyos1.fc45.src
EOF
cat >"$B/kernel/nvidia.env" <<'EOF'
kmod_srpm=nvidia-kmod-3:615.78.08-1.fc45.src
userspace=nvidia-driver-3:615.78.08-1.fc45.x86_64 2099da1e492b1abf2651c49b1a98f27ca215517bdddad06438769d0e25d2a6e4
EOF
http "$COPR_API/build/list/?ownername=bieszczaders&projectname=kernel-cachyos&packagename=kernel-cachyos&limit=30" <<'EOF'
{"items": [
 {"id": 301, "state": "failed", "source_package": {"version": null}},
 {"id": 300, "state": "failed", "source_package": {"version": "7.4.0-1.cachyos1"}},
 {"id": 250, "state": "succeeded", "source_package": {"version": "7.3.1-1.cachyos1"}},
 {"id": 200, "state": "succeeded", "source_package": {"version": "7.3.0-4.cachyos1"}},
 {"id": 150, "state": "succeeded", "source_package": {"version": "7.3.0-cachyos1"}}]}
EOF
chroot_state() { http "$COPR_API/build-chroot?build_id=$1&chrootname=fedora-45-x86_64" <<<"{\"state\": \"$2\"}"; }
MAINLINE_74=1793000000
releases() {
    http https://www.kernel.org/releases.json <<EOF
{"releases": [
 {"moniker": "mainline", "version": "7.4", "iseol": false, "released": {"timestamp": $MAINLINE_74}},
 {"moniker": "stable", "version": "7.3.2", "iseol": $1, "released": {"timestamp": 1792900000}},
 {"moniker": "longterm", "version": "6.18.60", "iseol": false, "released": {"timestamp": 1792900000}}]}
EOF
}
releases false
BUMP_ENV_SHA=$(cat "$B/kernel/kernel.env" "$B/kernel/nvidia.env" | sha256sum)
repo() {
    local dir=$1
    shift
    http "$NEG/$dir/repodata/repomd.xml" <<EOF
<repomd>
  <data type="other">
    <location href="repodata/x-other.xml.gz"/>
  </data>
  <data type="primary">
    <location href="repodata/x-primary.xml.gz"/>
  </data>
</repomd>
EOF
    local name arch epoch ver rel sum
    while read -r name arch epoch ver rel sum; do
        printf '<package type="rpm">\n  <name>%s</name>\n  <arch>%s</arch>\n  <version epoch="%s" ver="%s" rel="%s"/>\n  <checksum type="sha256" pkgid="YES">%s</checksum>\n</package>\n' \
            "$name" "$arch" "$epoch" "$ver" "$rel" "$sum"
    done <<<"$*" | gzip -c >"$B/http/$(printf '%s' "$NEG/$dir/repodata/x-primary.xml.gz" | tr -c 'A-Za-z0-9._-' '_')"
}
SUM_A=$(printf 'a%.0s' {1..64})
SUM_B=$(printf 'b%.0s' {1..64})
repo SRPMS "nvidia-kmod src 3 615.78.08 1.fc45 $SUM_A
nvidia-kmod src 3 615.80.01 1.fc45 $SUM_B
nvidia-kmod src 3 620.10 1.fc45 $SUM_A"
repo x86_64 "nvidia-driver x86_64 3 615.78.08 1.fc45 2099da1e492b1abf2651c49b1a98f27ca215517bdddad06438769d0e25d2a6e4
nvidia-driver i686 3 615.80.01 1.fc45 $SUM_B
nvidia-driver x86_64 3 620.10 1.fc45 $SUM_B"

bump() { PATH="$B/bin:$PATH" FAKE_HTTP="$B/http" BUMP_NOW=$((MAINLINE_74 + 6 * 86400)) "$B/kernel/bump.sh" check 2>&1; }

chroot_state 250 succeeded
chroot_state 300 succeeded
BUMP=$(bump)
check "bump: a point and a major bump both print, the point first" \
    "point kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src
major kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src waiting-for-owner EOL-in-10d" "$(grep -v '^nvidia ' <<<"$BUMP")"
check "bump: the newest kmod of the pinned branch" \
    "nvidia nvidia-kmod-3:615.80.01-1.fc45.src $SUM_B newer" "$(grep '^nvidia ' <<<"$BUMP" | sed -n 1p)"
check "bump: a userspace package still at its pin" \
    "nvidia nvidia-driver-3:615.78.08-1.fc45.x86_64 2099da1e492b1abf2651c49b1a98f27ca215517bdddad06438769d0e25d2a6e4 pinned" \
    "$(grep '^nvidia ' <<<"$BUMP" | sed -n 2p)"

chroot_state 300 failed
check "bump: a newer build of the pinned major alone is a point bump" "point kernel-cachyos-0:7.3.1-1.cachyos1.fc45.src" \
    "$(bump | grep -v '^nvidia ')"
chroot_state 300 succeeded

chroot_state 250 failed
check "bump: a newer major waits for the owner, with the EOL countdown" \
    "major kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src waiting-for-owner EOL-in-10d" "$(bump | grep -v '^nvidia ')"
releases true
check "bump: an EOL pinned major counts 0 days" \
    "major kernel-cachyos-0:7.4.0-1.cachyos1.fc45.src waiting-for-owner EOL-in-0d" "$(bump | grep -v '^nvidia ')"

chroot_state 300 failed
check "bump: no newer succeeded chroot build is none" none "$(bump | grep -v '^nvidia ')"

rm "$B/http/$(printf '%s' "$NEG/x86_64/repodata/repomd.xml" | tr -c 'A-Za-z0-9._-' '_')"
check "bump: an unreadable source means it cannot run" 2 \
    "$(PATH="$B/bin:$PATH" FAKE_HTTP="$B/http" rc_of "$B/kernel/bump.sh" check)"
check "bump: never edits the env files" "$BUMP_ENV_SHA" "$(cat "$B/kernel/kernel.env" "$B/kernel/nvidia.env" | sha256sum)"

check "check.sh: an unknown CHECK_SCOPE means it cannot run" 2 \
    "$(RPMS_DIR=$TMP CHECK_WORK=$TMP/cw MODULE_CERT=$TMP/none CHECK_SCOPE=both rc_of "$KERNEL_SRC/check.sh")"
