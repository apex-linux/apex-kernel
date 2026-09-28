#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Rebuild the libfprint SRPM that Fedora ships, with the Apex patches listed in
# packaging/libfprint/series (ADR 0006). Runs as root inside
# registry.fedoraproject.org/fedora:45 (libfprint.yml). The flow, the series format and
# the exit codes are described in packaging/libfprint/README.md.
#
# Usage: build.sh [build|key]
#   build (default)  rebuild; RPMs, manifest.txt and key.txt go to OUT_DIR
#   key              print the cache key (Fedora NVR + hash of the enabled patches,
#                    this script and the repository options)
#
# Environment:
#   OUT_DIR              required for build: empty or missing output directory
#   GA_REACHED           required: 1 once Fedora is GA, 0 before (adds updates-testing,
#                        restricted to TESTING_INCLUDEPKGS, when that is not empty)
#   SERIES               default packaging/libfprint/series (relative: to the repo root)
#   TESTING_INCLUDEPKGS  the compose's updates-testing allowlist (comma-separated
#                        includepkgs); only used when GA_REACHED=0. Empty: no
#                        updates-testing at all
#   APEX_SUFFIX          appended to %dist, default .apex1
#   RUN_TESTS            1 (default): run the elan driver replay tests; 0: skip them
#   KEEP_DEBUGINFO       1: also copy -debuginfo/-debugsource RPMs (default 0)
#   FEDORA_KEY_FPR       expected fingerprint of the Fedora release key; built in for 45
#   FEDORA_KEY_DIR       where the release key file is (default /usr/share/pki/rpm-gpg);
#                        the fingerprint check applies wherever it is
#   WORK_DIR             scratch directory (default: a new mktemp -d)
#
# Exit status: 0 built; 1 error (nothing usable was produced: investigate);
# 2 usage or configuration error; 3 degraded (a patch no longer applies or the patched
# build or its elan test failed: ship Fedora's stock libfprint, label the image
# degraded=fingerprint and open an issue; OUT_DIR/degraded.txt holds the reason).

set -euo pipefail

readonly EXIT_ERROR=1 EXIT_USAGE=2 EXIT_DEGRADED=3
# Fedora release keys, checked against the file shipped in the builder image before it
# is imported. Source: https://fedoraproject.org/security/ and fedora-repos dist-git
# (RPM-GPG-KEY-fedora-45-primary), both read on 2026-09-24.
readonly FEDORA_45_KEY_FPR=4F50A6114CD5C6976A7F1179655A4B02F577861E

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname -- "$SCRIPT_PATH")
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)
readonly SCRIPT_PATH SCRIPT_DIR REPO_ROOT

log() { printf '==> %s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit "$EXIT_ERROR"; }
usage_error() { printf 'usage error: %s\n' "$*" >&2; exit "$EXIT_USAGE"; }

# degrade REASON [LOGFILE]: record why the patched build cannot ship and exit 3.
degrade() {
	local reason=$1 logfile=${2:-}
	{
		printf 'libfprint degraded: %s\n' "$reason"
		printf 'fedora=%s stock=%s series=%s\n' "${FEDORA:-?}" "${STOCK_NVR:-?}" "$SERIES"
		if [[ -n $logfile && -f $logfile ]]; then
			printf '\nlast 60 lines of %s:\n' "${logfile##*/}"
			tail -n 60 -- "$logfile"
		fi
	} >"$OUT_DIR/degraded.txt"
	printf 'DEGRADED: %s\n' "$reason" >&2
	printf 'Ship stock libfprint with degraded=fingerprint; details in %s\n' \
		"$OUT_DIR/degraded.txt" >&2
	if [[ ${GITHUB_ACTIONS:-} == true ]]; then
		printf '::warning title=libfprint degraded::%s\n' "$reason"
	fi
	exit "$EXIT_DEGRADED"
}

MODE=${1:-build}
case $MODE in
build | key) ;;
-h | --help)
	# Print the header comment (everything up to the first non-comment line).
	awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$SCRIPT_PATH"
	exit 0
	;;
*) usage_error "unknown mode '$MODE' (build|key)" ;;
esac

[[ ${GA_REACHED:-} == 0 || ${GA_REACHED:-} == 1 ]] ||
	usage_error "GA_REACHED must be 0 or 1 (got '${GA_REACHED:-}')"
SERIES=${SERIES:-packaging/libfprint/series}
[[ $SERIES == /* ]] || SERIES=$REPO_ROOT/$SERIES
PATCH_DIR=$(dirname -- "$SERIES")/patches
APEX_SUFFIX=${APEX_SUFFIX:-.apex1}
[[ $APEX_SUFFIX =~ ^\.apex[0-9]+$ ]] || usage_error "APEX_SUFFIX must look like .apex1"
RUN_TESTS=${RUN_TESTS:-1}
KEEP_DEBUGINFO=${KEEP_DEBUGINFO:-0}
if [[ $MODE == build ]]; then
	[[ $(id -u) -eq 0 ]] || usage_error "run as root inside the Fedora container"
	[[ -n ${OUT_DIR:-} ]] || usage_error "OUT_DIR is required"
	mkdir -p -- "$OUT_DIR"
	OUT_DIR=$(cd -- "$OUT_DIR" && pwd)
	[[ -z $(ls -A -- "$OUT_DIR") ]] || usage_error "OUT_DIR $OUT_DIR is not empty"
fi

# --- series -----------------------------------------------------------------------
# One patch file name per line, relative to $PATCH_DIR; '#' starts a comment. 01xx
# patches are carried in the tree but disabled, so the series may not name them.
[[ -f $SERIES ]] || usage_error "series file $SERIES not found"
PATCHES=()
while IFS= read -r line || [[ -n $line ]]; do
	line=${line%%#*}
	line=${line#"${line%%[![:space:]]*}"}
	line=${line%"${line##*[![:space:]]}"}
	[[ -n $line ]] || continue
	[[ $line =~ ^[0-9]{4}-[A-Za-z0-9._-]+\.patch$ ]] ||
		usage_error "series entry '$line' is not a NNNN-name.patch file name"
	[[ $line != 01[0-9][0-9]-* ]] ||
		usage_error "series entry '$line' is an 01xx (disabled) patch; renumber it to enable it"
	[[ -f $PATCH_DIR/$line ]] || usage_error "series entry '$line' not found in $PATCH_DIR"
	for seen in "${PATCHES[@]}"; do
		[[ $seen != "$line" ]] || usage_error "series lists '$line' twice"
	done
	PATCHES+=("$line")
done <"$SERIES"
((${#PATCHES[@]} > 0)) ||
	usage_error "series enables no patch; drop the libfprint job instead (README.md)"

# --- repositories -----------------------------------------------------------------
# Exactly the repositories the image compose resolves from (ARCHITECTURE section 3),
# so the rebuilt SRPM is the version the compose would otherwise install: fedora and
# updates, plus updates-testing only while GA_REACHED=0 AND the allowlist has entries,
# restricted to them (includepkgs). An empty allowlist means no updates-testing at all,
# as in the Containerfile, which then generates no apex-gnome51 stanza; the pre-GA
# fedora:45 image enables all of updates-testing, so the defaults are never used.
FEDORA=$(rpm -E '%fedora')
ARCH=$(rpm -E '%_arch')
[[ $FEDORA =~ ^[0-9]+$ ]] || die "not a Fedora system (rpm -E %fedora = '$FEDORA')"
BIN_REPOS=(--repo=fedora --repo=updates)
SRC_REPOS=(--repo=fedora-source --repo=updates-source)
SETOPTS=(--setopt=install_weak_deps=False)
if [[ $GA_REACHED == 0 && -n ${TESTING_INCLUDEPKGS:-} ]]; then
	BIN_REPOS+=(--repo=updates-testing)
	SRC_REPOS+=(--repo=updates-testing-source)
	SETOPTS+=("--setopt=updates-testing.includepkgs=$TESTING_INCLUDEPKGS")
elif [[ $GA_REACHED == 0 ]]; then
	log "GA_REACHED=0, empty updates-testing allowlist: updates-testing stays disabled (as in the compose)"
fi
dnf_bin() { dnf5 -y -q "${BIN_REPOS[@]}" "${SETOPTS[@]}" "$@"; }

# The series hash covers the patch contents, the suffix, this script and the
# repository options (they decide the build dependencies), so any change that alters
# the output also changes the cache key.
SERIES_SHA256=$(
	{
		printf 'suffix %s\n' "$APEX_SUFFIX"
		printf 'script %s\n' "$(sha256sum <"$SCRIPT_PATH" | cut -d' ' -f1)"
		printf 'repos %s %s\n' "${BIN_REPOS[*]}" "${SETOPTS[*]}"
		for p in "${PATCHES[@]}"; do
			printf 'patch %s %s\n' "$p" "$(sha256sum <"$PATCH_DIR/$p" | cut -d' ' -f1)"
		done
	} | sha256sum | cut -d' ' -f1
)

log "Resolving libfprint.$ARCH in: ${BIN_REPOS[*]#--repo=}"
query=$(dnf_bin repoquery --latest-limit=1 --arch="$ARCH" \
	--queryformat='%{name} %{epoch} %{version} %{release} %{sourcerpm}\n' libfprint)
[[ $(wc -l <<<"$query") -eq 1 && -n $query ]] ||
	die "expected one libfprint.$ARCH, repoquery returned: '$query'"
read -r _ STOCK_EPOCH STOCK_VERSION STOCK_RELEASE STOCK_SOURCERPM <<<"$query"
STOCK_NVR=libfprint-$STOCK_VERSION-$STOCK_RELEASE
[[ $STOCK_SOURCERPM == "$STOCK_NVR.src.rpm" ]] ||
	die "libfprint.$ARCH comes from $STOCK_SOURCERPM, not $STOCK_NVR.src.rpm"
KEY="$STOCK_NVR-s${SERIES_SHA256:0:12}"

if [[ $MODE == key ]]; then
	printf '%s\n' "$KEY"
	exit 0
fi
log "Stock: $STOCK_NVR (epoch $STOCK_EPOCH); patches: ${PATCHES[*]}; key $KEY"

WORK_DIR=${WORK_DIR:-$(mktemp -d -t apex-libfprint.XXXXXX)}
mkdir -p -- "$WORK_DIR"
TOP=$WORK_DIR/rpmbuild
mkdir -p -- "$TOP"/{BUILD,RPMS,SOURCES,SPECS,SRPMS} "$WORK_DIR/srpm"
log "Work directory: $WORK_DIR"

log "Installing build tools"
dnf_bin install rpm-build dnf5-plugins git-core cpio /usr/bin/gpg >/dev/null

# --- SRPM download and signature ----------------------------------------------------
# dnf checks the SRPM against the metalink-anchored metadata but not its OpenPGP
# signature, so verify it here against the pinned Fedora key before using it.
log "Downloading $STOCK_SOURCERPM"
stock_spec=libfprint-$STOCK_VERSION-$STOCK_RELEASE.$ARCH
[[ $STOCK_EPOCH == 0 ]] || stock_spec=libfprint-$STOCK_EPOCH:$STOCK_VERSION-$STOCK_RELEASE.$ARCH
dnf5 -y -q "${BIN_REPOS[@]}" "${SRC_REPOS[@]}" "${SETOPTS[@]}" \
	download --srpm --destdir="$WORK_DIR/srpm" "$stock_spec" >/dev/null
SRPM=$WORK_DIR/srpm/$STOCK_SOURCERPM
[[ -f $SRPM ]] || die "dnf did not download $STOCK_SOURCERPM"

key_file=${FEDORA_KEY_DIR:-/usr/share/pki/rpm-gpg}/RPM-GPG-KEY-fedora-$FEDORA-primary
[[ -f $key_file ]] || die "$key_file not found in the builder image"
expected_fpr=${FEDORA_KEY_FPR:-}
if [[ -z $expected_fpr && $FEDORA == 45 ]]; then
	expected_fpr=$FEDORA_45_KEY_FPR
fi
[[ -n $expected_fpr ]] || usage_error "set FEDORA_KEY_FPR for Fedora $FEDORA"
gnupg_home=$WORK_DIR/gnupg
# chmod separately: with -p, mkdir -m applies only to the last directory, and a
# pre-existing one would keep its mode.
mkdir -p -- "$gnupg_home"
chmod 0700 -- "$gnupg_home"
key_fpr=$(gpg --homedir "$gnupg_home" --batch --show-keys --with-colons -- "$key_file" |
	awk -F: '$1 == "fpr" { print $10; exit }')
[[ ${key_fpr^^} == "${expected_fpr^^}" ]] ||
	die "$key_file has fingerprint '$key_fpr', expected $expected_fpr"
rpmkeys --import "$key_file"

# Both the summary and every signature line must be OK, and one signature must be
# made by the Fedora key (its key ID is the tail of the fingerprint). With -v, rpm
# prints one line per digest or signature and no summary; signature lines read
# "Header V4 RSA/SHA256 Signature, key ID f577861e: OK" (rpm 4) or "Header OpenPGP V4
# RSA/SHA256 Signature, key fingerprint: 4f50...861e: OK" (rpm 6, lib/rpmvs.cc).
checksig=$(rpmkeys --checksig -- "$SRPM" 2>&1) || die "rpmkeys -K failed: $checksig"
printf '%s\n' "$checksig" >&2
[[ $checksig == *"signatures OK"* ]] || die "SRPM signatures are not OK: $checksig"
checksig_v=$(rpmkeys --checksig -v -- "$SRPM" 2>&1) || die "rpmkeys -Kv failed"
key_id=${expected_fpr: -8}
fedora_signed=0
while IFS= read -r line; do
	[[ ${line,,} == *signature* ]] || continue
	[[ $line == *": OK" ]] || die "SRPM signature check: $line"
	if [[ ${line,,} == *"signature, key"*"${key_id,,}"* ]]; then
		fedora_signed=1
	fi
done <<<"$checksig_v"
((fedora_signed)) || die "no signature by the Fedora $FEDORA key (${key_id}):"$'\n'"$checksig_v"
log "SRPM signed by the Fedora $FEDORA key: OK"

# --- unpack and NVR checks ----------------------------------------------------------
(cd -- "$TOP/SOURCES" && rpm2cpio "$SRPM" | cpio -idm --quiet --no-absolute-filenames)
specs=("$TOP"/SOURCES/*.spec)
[[ ${#specs[@]} -eq 1 && -f ${specs[0]} ]] || die "SRPM holds ${#specs[@]} spec files"
SPEC=$TOP/SPECS/libfprint.spec
mv -- "${specs[0]}" "$SPEC"

# Fedora's spec says Release: %autorelease; Koji's SRPM carries the rpmautospec
# preamble that expands it to the real release number followed by %{?dist}. Prove it:
# with the stock dist the spec must give the stock release, and with the Apex dist it
# must give the stock release plus the suffix (1.fc45 -> 1.fc45.apex1).
BASE_DIST=$(rpm -E '%{?dist}')
[[ $BASE_DIST == ".fc$FEDORA" ]] || die "unexpected %dist '$BASE_DIST'"
[[ $STOCK_RELEASE == *"$BASE_DIST" ]] ||
	die "stock release $STOCK_RELEASE does not end in $BASE_DIST; cannot add $APEX_SUFFIX"
APEX_DIST=$BASE_DIST$APEX_SUFFIX
APEX_RELEASE=$STOCK_RELEASE$APEX_SUFFIX
spec_release() {
	rpmspec -q --srpm --queryformat='%{version}-%{release}\n' \
		--define "_topdir $TOP" --define "dist $1" -- "$SPEC"
}
got=$(spec_release "$BASE_DIST")
[[ $got == "$STOCK_VERSION-$STOCK_RELEASE" ]] ||
	die "spec gives $got with dist $BASE_DIST, Fedora built $STOCK_VERSION-$STOCK_RELEASE" \
		"(is %autorelease expanded in the SRPM?)"
got=$(spec_release "$APEX_DIST")
[[ $got == "$STOCK_VERSION-$APEX_RELEASE" ]] ||
	die "spec gives $got with dist $APEX_DIST, expected $STOCK_VERSION-$APEX_RELEASE"

# rpm's own comparison (rpm.vercmp, i.e. rpmvercmp on EVR strings); first a sanity
# check of the comparator itself, then the real pair.
vercmp() { rpm -E "%{lua: print(rpm.vercmp('$1', '$2'))}"; }
[[ $(vercmp 1-1.fc45.apex1 1-1.fc45) == 1 && $(vercmp 1-2.fc45 1-1.fc45.apex1) == 1 ]] ||
	die "rpm.vercmp does not order dist suffixes as expected"
stock_evr=$STOCK_VERSION-$STOCK_RELEASE
apex_evr=$STOCK_VERSION-$APEX_RELEASE
if [[ $STOCK_EPOCH != 0 ]]; then
	stock_evr=$STOCK_EPOCH:$stock_evr
	apex_evr=$STOCK_EPOCH:$apex_evr
fi
[[ $(vercmp "$apex_evr" "$stock_evr") == 1 ]] || die "$apex_evr does not sort above $stock_evr"
log "NVR: libfprint-$STOCK_VERSION-$APEX_RELEASE sorts above $STOCK_NVR"

# --- build dependencies and pristine %prep -------------------------------------------
log "Installing build dependencies"
dnf_bin builddep "$SRPM" >/dev/null

# srcdir: the unpacked source tree under BUILD. rpm >= 4.20 nests it one level deeper
# (BUILD/NAME-VERSION-build/SRC); the shallowest meson.build is the project root.
srcdir() {
	local found
	found=$(find "$TOP/BUILD" -mindepth 2 -maxdepth 3 -name meson.build -printf '%d %h\n' |
		sort -n | head -n 1 | cut -d' ' -f2-)
	[[ -n $found ]] || return 1
	printf '%s\n' "$found"
}
rpmbuild_in() {
	rpmbuild --define "_topdir $TOP" --define "dist $APEX_DIST" "$@"
}

log "Checking that Fedora's %prep works unpatched"
rpmbuild_in -bp "$SPEC" >"$WORK_DIR/prep-stock.log" 2>&1 || {
	tail -n 40 "$WORK_DIR/prep-stock.log" >&2
	die "%prep fails without any Apex patch; the builder or the SRPM is broken"
}
stock_src=$(srcdir) || die "no source tree under $TOP/BUILD after %prep"
cp -a -- "$stock_src" "$WORK_DIR/pristine"

# --- patch the spec -----------------------------------------------------------------
grep -Eq '^%(autosetup|autopatch)([[:space:]]|$)' "$SPEC" ||
	degrade "Fedora's spec no longer uses %autosetup/%autopatch; Patch lines would be ignored"
: >"$WORK_DIR/patch-lines"
n=1000
for p in "${PATCHES[@]}"; do
	n=$((n + 1))
	install -m 0644 -- "$PATCH_DIR/$p" "$TOP/SOURCES/apex-$p"
	printf 'Patch%d: apex-%s\n' "$n" "$p" >>"$WORK_DIR/patch-lines"
done
awk -v lines="$WORK_DIR/patch-lines" '
	{ print }
	!done && /^Source0?[[:space:]]*:/ {
		while ((getline l < lines) > 0) print l
		done = 1
	}
	END { exit done ? 0 : 1 }
' "$SPEC" >"$SPEC.new" || degrade "no Source0: line in Fedora's spec to insert patches after"
mv -- "$SPEC.new" "$SPEC"
log "Added to the spec:"$'\n'"$(cat "$WORK_DIR/patch-lines")"

log "Applying the series (%prep)"
rpmbuild_in -bp "$SPEC" >"$WORK_DIR/prep-apex.log" 2>&1 ||
	degrade "a patch in the series no longer applies to $STOCK_NVR" "$WORK_DIR/prep-apex.log"

# Prove the tree is exactly pristine + series: reverting the patches in reverse order
# must give back the unpatched tree.
patched_src=$(srcdir) || die "no source tree under $TOP/BUILD after patched %prep"
cp -a -- "$patched_src" "$WORK_DIR/reverted"
for ((i = ${#PATCHES[@]} - 1; i >= 0; i--)); do
	(cd -- "$WORK_DIR/reverted" && git apply -R -p1 -- "$PATCH_DIR/${PATCHES[i]}") ||
		degrade "${PATCHES[i]} is not applied as written in the %prep tree"
done
diff -r -q --exclude=.git -- "$WORK_DIR/pristine" "$WORK_DIR/reverted" >"$WORK_DIR/revert.diff" ||
	degrade "the %prep tree differs from Fedora's source plus the series" "$WORK_DIR/revert.diff"
log "Series applied exactly"

# --- build --------------------------------------------------------------------------
# Fedora's spec has no %check today (its test run needs a pygobject fix), so no
# --nocheck: if Fedora restores %check it runs here too. --noclean keeps the build
# tree for the elan replay tests below.
log "Building libfprint-$STOCK_VERSION-$APEX_RELEASE"
rpmbuild_in -bb --noclean "$SPEC" >"$WORK_DIR/build.log" 2>&1 ||
	degrade "the patched libfprint does not build" "$WORK_DIR/build.log"

# --- tests --------------------------------------------------------------------------
# The umockdev replay tests need no hardware. The elan tests replay a recorded capture
# through the patched driver; a control test of an untouched driver tells a broken
# test harness (inconclusive, warn) from a driver regression (degrade).
TESTS=skipped
if [[ $RUN_TESTS == 1 ]]; then
	# %meson builds in %{_vpath_builddir} (redhat-linux-build) inside the source tree.
	build_dir=
	if src=$(srcdir); then
		build_dir=$src/redhat-linux-build
	fi
	if [[ -z $build_dir || ! -d $build_dir ]]; then
		TESTS=unavailable
		warn "no meson build directory under $TOP/BUILD; tests not run"
	else
		# `meson test --list` prints "suites - project:name" (meson 1.x, e.g.
		# "drivers - libfprint:elan"), "project:suites / name" (older) or "name".
		mapfile -t all_tests < <(meson test -C "$build_dir" --list 2>"$WORK_DIR/tests-list.err" |
			sed -e 's/[[:space:]]*$//' -e 's|.* / ||' -e 's|.* - [^:]*:||')
		elan_tests=()
		control=
		for t in "${all_tests[@]}"; do
			# elan and elan-cobo use the patched driver; elanmoc and elanspi do not.
			if [[ $t =~ ^elan(-[A-Za-z0-9_]+)?$ ]]; then
				elan_tests+=("$t")
			fi
			if [[ -z $control && $t =~ ^(aes3500|vfs5011|synaptics)$ ]]; then
				control=$t
			fi
		done
		run_meson_test() {
			meson test -C "$build_dir" --print-errorlogs --timeout-multiplier 4 "$@" \
				>>"$WORK_DIR/tests.log" 2>&1
		}
		if ((${#elan_tests[@]} == 0)) || [[ -z $control ]]; then
			TESTS=unavailable
			warn "elan or control replay tests not found; tests not run (${#all_tests[@]} tests listed in $build_dir)"
			if [[ -s $WORK_DIR/tests-list.err ]]; then
				head -n 20 "$WORK_DIR/tests-list.err" >&2
			fi
			((${#all_tests[@]} == 0)) || printf '  listed: %s\n' "${all_tests[*]:0:40}" >&2
		elif ! run_meson_test "$control"; then
			TESTS=inconclusive
			warn "control test $control fails too: the test harness is broken, not the patch"
			tail -n 30 "$WORK_DIR/tests.log" >&2
		elif ! run_meson_test "${elan_tests[@]}"; then
			degrade "the patched elan driver fails its replay test (${elan_tests[*]})" \
				"$WORK_DIR/tests.log"
		else
			TESTS=passed
		fi
	fi
fi
log "Tests: $TESTS"

# --- outputs ------------------------------------------------------------------------
mapfile -t rpms < <(find "$TOP/RPMS" -type f -name '*.rpm' | sort)
((${#rpms[@]} > 0)) || die "rpmbuild produced no RPMs"
nevra() { rpm -qp --queryformat='%{name}-%{epochnum}:%{version}-%{release}.%{arch}' -- "$1"; }
main_rpm=
for f in "${rpms[@]}"; do
	if [[ $(rpm -qp --queryformat='%{name}' -- "$f") == libfprint ]]; then
		main_rpm=$f
	fi
done
[[ -n $main_rpm ]] || die "no libfprint binary RPM among: ${rpms[*]##*/}"
[[ $(rpm -qp --queryformat='%{release}' -- "$main_rpm") == "$APEX_RELEASE" ]] ||
	die "built release is not $APEX_RELEASE: ${main_rpm##*/}"

{
	printf '# apex-libfprint manifest 1: kind nevra sha256 file\n'
	printf '# key=%s fedora=%s ga_reached=%s dist=%s tests=%s\n' \
		"$KEY" "$FEDORA" "$GA_REACHED" "$APEX_DIST" "$TESTS"
	printf 'srpm %s %s %s\n' \
		"$(rpm -qp --queryformat='%{name}-%{epochnum}:%{version}-%{release}.src' -- "$SRPM")" \
		"$(sha256sum <"$SRPM" | cut -d' ' -f1)" "${SRPM##*/}"
	for p in "${PATCHES[@]}"; do
		printf 'patch %s %s %s\n' "${p%.patch}" \
			"$(sha256sum <"$PATCH_DIR/$p" | cut -d' ' -f1)" "$p"
	done
	for f in "${rpms[@]}"; do
		if [[ $KEEP_DEBUGINFO != 1 && ${f##*/} =~ -debug(info|source)- ]]; then
			continue
		fi
		cp -- "$f" "$OUT_DIR/"
		printf 'rpm %s %s %s\n' "$(nevra "$f")" "$(sha256sum <"$f" | cut -d' ' -f1)" "${f##*/}"
	done
} >"$OUT_DIR/manifest.txt"
printf '%s\n' "$KEY" >"$OUT_DIR/key.txt"
cat -- "$OUT_DIR/manifest.txt"
log "Done: $OUT_DIR"
