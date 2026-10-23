# SPDX-License-Identifier: GPL-3.0-or-later
#
# Recipes never run sudo: the ones that need root print the command instead.

set shell := ["bash", "-euo", "pipefail", "-c"]

# List the recipes.
default:
    @just --list

# shellcheck and the script self-tests, as ci.yml runs them.
check:
    shellcheck -x -P .github/scripts --severity=style .github/scripts/*.sh packaging/libfprint/build.sh packaging/pkgs/kernel/*.sh
    .github/scripts/selftest.sh

# Print the libfprint cache key (Fedora's NVR plus a hash of the enabled patches).
libfprint-key:
    .github/scripts/libfprint.sh key

# Print the command that rebuilds libfprint in a fedora:45 container (root).
libfprint:
    @echo 'sudo podman run --rm -v "$PWD:/src:z" -w /src registry.fedoraproject.org/fedora:45 .github/scripts/libfprint.sh build /src/_build/libfprint   # exit 3 = degraded'
