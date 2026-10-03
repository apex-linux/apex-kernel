#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail

readonly PRIVATE_KEY_WITH_CERTIFICATE=signing_key.pem
readonly CERTIFICATE_DER=signing_key.x509
readonly VALID_DAYS=36500

usage() {
    cat <<'EOF'
usage: module-key.sh generate DIR COMMON-NAME
       module-key.sh shred DIR

The module-signing key of one kernel and NVIDIA pair build (ADR 0015).

generate  writes DIR/signing_key.pem, an ECDSA P-384 private key followed by its
          self-signed certificate (the file CONFIG_MODULE_SIG_KEY names), and
          DIR/signing_key.x509, the certificate alone in DER. DIR must be an empty
          tmpfs. Prints the certificate's serial and SHA-256 fingerprint.
shred     overwrites and removes the private key. The certificate stays.
EOF
}

die() { printf 'module-key.sh: %s\n' "$*" >&2; exit 1; }

require_empty_tmpfs() {
    local dir=$1
    [[ -d $dir ]] || die "$dir is not a directory"
    [[ $(stat --file-system --format=%T -- "$dir") == tmpfs ]] ||
        die "$dir is not on a tmpfs: the private key must never reach a disk"
    [[ -z $(ls -A -- "$dir") ]] || die "$dir is not empty"
}

# The extensions of the kernel's own certs/default_x509.genkey.
request_config() {
    local common_name=$1
    cat <<EOF
[ req ]
distinguished_name = subject
prompt = no
string_mask = utf8only
x509_extensions = extensions

[ subject ]
CN = $common_name

[ extensions ]
basicConstraints = critical,CA:FALSE
keyUsage = digitalSignature
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF
}

generate() {
    local dir=$1 common_name=$2
    [[ $common_name =~ ^[A-Za-z0-9][A-Za-z0-9._+\ -]*$ ]] ||
        die "the common name may hold letters, digits, spaces and . _ + - only, got '$common_name'"
    require_empty_tmpfs "$dir"
    umask 077
    request_config "$common_name" >"$dir/request.conf"
    openssl req -new -x509 -nodes -utf8 -batch -sha512 -days "$VALID_DAYS" \
        -newkey ec -pkeyopt ec_paramgen_curve:secp384r1 -config "$dir/request.conf" \
        -outform PEM -keyout "$dir/$PRIVATE_KEY_WITH_CERTIFICATE" -out "$dir/$PRIVATE_KEY_WITH_CERTIFICATE" 2>/dev/null ||
        die "openssl could not generate the key"
    rm -f -- "$dir/request.conf"
    openssl x509 -in "$dir/$PRIVATE_KEY_WITH_CERTIFICATE" -outform DER -out "$dir/$CERTIFICATE_DER"
    chmod 0644 -- "$dir/$CERTIFICATE_DER"
    openssl x509 -inform DER -in "$dir/$CERTIFICATE_DER" -noout -subject -serial -fingerprint -sha256
}

shred_private_key() {
    local dir=$1
    [[ -f $dir/$PRIVATE_KEY_WITH_CERTIFICATE ]] || die "no $PRIVATE_KEY_WITH_CERTIFICATE in $dir"
    shred --remove -- "$dir/$PRIVATE_KEY_WITH_CERTIFICATE"
}

main() {
    case ${1:-} in
        generate) (($# == 3)) || { usage >&2; exit 2; }; generate "$2" "$3" ;;
        shred) (($# == 2)) || { usage >&2; exit 2; }; shred_private_key "$2" ;;
        -h | --help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
