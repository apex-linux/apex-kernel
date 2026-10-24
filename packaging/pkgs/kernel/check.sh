#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# apex-lane's contract (packaging/README.md): exit 1 holds the family, the last line
# giving the reason; exit 2 means the checks could not run.

set -euo pipefail

usage() {
    cat <<'EOF'
usage: RPMS_DIR=DIR CHECK_WORK=DIR MODULE_CERT=FILE [CHECK_SCOPE=pair|kernel] check.sh

The lane checks of one kernel and NVIDIA pair (ADR 0015), run in the build container:

  - the built kernel's config has every line of config-required.txt;
  - the certificates built into vmlinuz are exactly MODULE_CERT, the DER certificate of
    this build's module key (module-key.sh);
  - every module of kernel-cachyos-modules and of kmod-nvidia names that certificate as
    its signer, with SHA-512 or SHA-256, and has the kernel's vermagic;
  - the signature of every NVIDIA module verifies against MODULE_CERT;
  - kmod-nvidia requires exactly this kernel;
  - no payload file holds a PEM private key.

RPMS_DIR holds the built RPMs (kernel-cachyos-core, -modules, -devel, and kmod-nvidia
when the pair has one); CHECK_WORK is scratch, created here. CHECK_SCOPE=kernel checks
the kernel alone, for a kernel whose kmod failed: it ignores any kmod-nvidia RPM, and
checks that kernel-cachyos-core provides kernel-uname-r = its release instead.
EOF
}

# The magic ends with a newline, which a command substitution drops.
readonly MODULE_SIGNATURE_MAGIC='~Module signature appended~'
readonly MODULE_SIGNATURE_MAGIC_BYTES=28
readonly MODULE_SIGNATURE_STRUCT_BYTES=12
readonly SIGNATURE_LENGTH_FIELD_BYTES=4

ok() { printf 'ok %s\n' "$*"; }
fail() { printf 'not ok: %s\n' "$*" >&2; exit 1; }
cannot() { printf 'check.sh cannot run: %s\n' "$*" >&2; exit 2; }

unpack() {
    local rpm=$1
    (cd -- "$root" && rpm2cpio "$rpm" | cpio -idmu --quiet --no-absolute-filenames) ||
        cannot "cannot unpack ${rpm##*/}"
}

only_rpm() {
    local pattern=$1
    local -a found
    mapfile -t found < <(find "$RPMS_DIR" -type f -name "$pattern")
    ((${#found[@]} == 1)) || fail "expected one $pattern, found ${#found[@]}"
    printf '%s\n' "${found[0]}"
}

certificate_field() {
    openssl x509 -inform DER -in "$MODULE_CERT" -noout "$@"
}

check_config() {
    local config=$1 line
    local -a missing=()
    while IFS= read -r line; do
        grep -Fxq -- "$line" "$config" || missing+=("$line")
    done < <(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$here/config-required.txt")
    ((${#missing[@]} == 0)) || fail "the kernel config lacks: ${missing[*]}"
    ok "the kernel config has every line of config-required.txt"
}

check_builtin_certificate() {
    local vmlinux=$CHECK_WORK/vmlinux builtin=$CHECK_WORK/builtin-certificates.der
    "$kernel_tree/scripts/extract-vmlinux" "$modules/vmlinuz" >"$vmlinux" ||
        cannot "extract-vmlinux cannot unpack vmlinuz"
    perl "$kernel_tree/scripts/extract-sys-certs.pl" -s "$modules/System.map" "$vmlinux" "$builtin" >/dev/null ||
        cannot "extract-sys-certs.pl found no certificate list in vmlinuz"
    cmp -s -- "$builtin" "$MODULE_CERT" ||
        fail "the certificates built into vmlinuz are not exactly this build's module certificate"
    ok "vmlinuz trusts exactly this build's module certificate ($(certificate_field -fingerprint -sha256))"
}

# modinfo prints the signer's certificate serial as sig_key, in colon-separated bytes.
check_module_signers() {
    local serial signer report=$CHECK_WORK/modules.txt
    serial=$(certificate_field -serial | sed -e 's/^serial=//' -e 's/../&:/g' -e 's/:$//')
    signer=$(certificate_field -subject -nameopt multiline | sed -n 's/^ *commonName *= //p')
    find "$modules" -type f -name '*.ko*' -print0 | xargs -0 modinfo |
        awk -v release="$release" -v serial="$serial" -v signer="$signer" '
            function field() { sub(/^[^:]*:[[:space:]]*/, ""); return $0 }
            function close_module() {
                if (file == "") return
                total++
                if (vermagic != release) bad[file] = "vermagic " vermagic
                else if (key != serial || who != signer) bad[file] = "signed by " who " " key
                else if (hash != "sha512" && hash != "sha256") bad[file] = "hash " hash
            }
            /^filename:/ { close_module(); file = field(); vermagic = key = who = hash = "" }
            /^vermagic:/ { vermagic = field(); sub(/ .*/, "", vermagic) }
            /^sig_key:/ { key = field() }
            /^signer:/ { who = field() }
            /^sig_hashalgo:/ { hash = field() }
            END {
                close_module()
                print "modules " total
                for (f in bad) print "bad " f ": " bad[f]
            }' >"$report"
    if grep -q '^bad ' "$report"; then
        grep '^bad ' "$report" | head -n 20 >&2
        fail "$(grep -c '^bad ' "$report") module(s) lack this build's signature or the kernel's vermagic"
    fi
    module_count=$(sed -n 's/^modules //p' "$report")
    ((module_count > 0)) || fail "the pair has no modules"
    ok "$module_count modules are signed by \"$signer\" ($serial) for $release"
}

uncompressed() {
    case $1 in
        *.ko) cat -- "$1" ;;
        *.ko.xz) xz --decompress --stdout -- "$1" ;;
        *.ko.zst) zstd --decompress --stdout --quiet -- "$1" ;;
        *) return 1 ;;
    esac
}

# The signature block ends the file: PKCS#7, struct module_signature, then the magic.
# The struct's last field is the PKCS#7 length, big-endian.
verify_module_signature() {
    local packed=$1 module=$CHECK_WORK/module.ko certificate=$CHECK_WORK/module-cert.pem
    local size signature_bytes trailer_bytes
    uncompressed "$packed" >"$module" || cannot "cannot read ${packed##*/}"
    [[ $(tail -c "$MODULE_SIGNATURE_MAGIC_BYTES" "$module") == "$MODULE_SIGNATURE_MAGIC" ]] ||
        fail "${packed##*/} carries no signature"
    size=$(stat --format=%s -- "$module")
    trailer_bytes=$((MODULE_SIGNATURE_MAGIC_BYTES + MODULE_SIGNATURE_STRUCT_BYTES))
    signature_bytes=$((16#$(tail -c "$((MODULE_SIGNATURE_MAGIC_BYTES + SIGNATURE_LENGTH_FIELD_BYTES))" "$module" |
        head -c "$SIGNATURE_LENGTH_FIELD_BYTES" | od -An -tx1 | tr -d ' \n')))
    head -c "$((size - trailer_bytes - signature_bytes))" "$module" >"$CHECK_WORK/module.body"
    tail -c "$((trailer_bytes + signature_bytes))" "$module" | head -c "$signature_bytes" >"$CHECK_WORK/module.p7s"
    openssl x509 -inform DER -in "$MODULE_CERT" -outform PEM -out "$certificate"
    openssl cms -verify -binary -inform DER -in "$CHECK_WORK/module.p7s" -content "$CHECK_WORK/module.body" \
        -certfile "$certificate" -nointern -noverify -out /dev/null 2>/dev/null ||
        fail "the signature of ${packed##*/} does not verify against this build's certificate"
}

check_nvidia() {
    local kmod=$1 module requires
    local -a nvidia_modules
    requires=$(rpm --query --package --nosignature --requires -- "$kmod")
    grep -Fxq -- "kernel-uname-r = $release" <<<"$requires" ||
        fail "${kmod##*/} does not require kernel-uname-r = $release"
    mapfile -t nvidia_modules < <(find "$modules/extra" -type f -name '*.ko*')
    ((${#nvidia_modules[@]} > 0)) || fail "${kmod##*/} holds no module"
    for module in "${nvidia_modules[@]}"; do
        verify_module_signature "$module"
    done
    ok "${#nvidia_modules[@]} NVIDIA modules verify against the certificate; ${kmod##*/} requires this kernel"
}

check_kernel_uname_r() {
    local core=$1
    rpm --query --package --nosignature --provides -- "$core" | grep -Fxq -- "kernel-uname-r = $release" ||
        fail "${core##*/} does not provide kernel-uname-r = $release"
    ok "${core##*/} provides kernel-uname-r = $release"
}

check_no_private_key() {
    local found
    found=$(grep -rlE --exclude='*.ko.*' -e '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' -- "$root" | head -n 5 || true)
    [[ -z $found ]] || fail "a payload file holds a private key: ${found//$'\n'/ }"
    ok "no payload file holds a PEM private key"
}

main() {
    case ${1:-} in -h | --help) usage; exit 0 ;; esac
    local v tool pattern package core scope=${CHECK_SCOPE:-pair}
    [[ $scope == pair || $scope == kernel ]] || cannot "CHECK_SCOPE is pair or kernel, not '$scope'"
    for v in RPMS_DIR CHECK_WORK MODULE_CERT; do
        [[ -n ${!v:-} ]] || cannot "$v is not set"
    done
    for tool in modinfo openssl perl objdump file cmp zstd xz cpio rpm2cpio; do
        command -v "$tool" >/dev/null || cannot "no $tool in the buildroot"
    done
    perl -MMath::BigInt -e 1 2>/dev/null || cannot "no perl Math::BigInt in the buildroot: extract-sys-certs.pl needs it"
    [[ -s $MODULE_CERT ]] || cannot "no module certificate at $MODULE_CERT"

    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    root=$CHECK_WORK/root
    # Fedora's /lib is /usr/lib, and the payloads name either.
    mkdir -p -- "$root/usr/lib"
    ln -s usr/lib "$root/lib"
    for pattern in 'kernel-cachyos-core-[0-9]*.rpm' 'kernel-cachyos-modules-[0-9]*.rpm' 'kernel-cachyos-devel-[0-9]*.rpm'; do
        package=$(only_rpm "$pattern")
        unpack "$package"
    done
    core=$(only_rpm 'kernel-cachyos-core-[0-9]*.rpm')
    release=$(rpm --query --package --nosignature --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' -- "$core")
    modules=$root/usr/lib/modules/$release
    kernel_tree=$root/usr/src/kernels/$release
    [[ -s $modules/vmlinuz && -s $modules/config && -d $kernel_tree/scripts ]] ||
        fail "the kernel RPMs do not hold vmlinuz, config and the kernel tree of $release"

    local -a kmods=()
    [[ $scope == kernel ]] ||
        mapfile -t kmods < <(find "$RPMS_DIR" -type f -name "kmod-nvidia-$release-[0-9]*.rpm")
    ((${#kmods[@]} <= 1)) || fail "expected at most one kmod-nvidia for $release, found ${#kmods[@]}"
    ((${#kmods[@]} == 0)) || unpack "${kmods[0]}"

    check_config "$modules/config"
    check_builtin_certificate
    check_module_signers
    ((${#kmods[@]} == 0)) || check_nvidia "${kmods[0]}"
    [[ $scope == pair ]] || check_kernel_uname_r "$core"
    check_no_private_key
}

main "$@"
