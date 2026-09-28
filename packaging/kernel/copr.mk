# SPDX-License-Identifier: GPL-3.0-or-later
#
# copr.mk: SRPM recipe for the Apex kernel in COPR's "make_srpm" form (M2, deferred;
# see README.md in this directory for the adoption gates of ADR 0005).
#
# COPR runs:  make -f <dir>/.copr/Makefile srpm outdir=<dir> spec=<ignored>
# Locally (root in a Fedora 45 container or the builder VM):
#             make -f packaging/kernel/copr.mk srpm outdir="$PWD/target/kernel-srpm"
#
# It clones Fedora's kernel dist-git at one pinned commit, downloads every lookaside
# source and checks it against the SHA512 recorded in that commit, drops in
# kernel-local, the enabled patches (as linux-kernel-test.patch) and the spec header
# from this directory, and builds the SRPM. Nothing else in Fedora's spec changes.

# This directory, taken before any other include changes MAKEFILE_LIST.
HERE := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

DISTGIT        ?= https://src.fedoraproject.org/rpms/kernel.git
# Koji's source commit of kernel-7.2.7-300.fc45 (checked 2026-09-24 with
#   koji buildinfo kernel-7.2.7-300.fc45, or getBuild(...)['source'] over XML-RPC).
# Bump it, in a reviewed PR, for every Fedora 45 stable kernel.
DISTGIT_COMMIT ?= 353f6aa0fe79acfdb1bf7d3d710c30a6a4e97812
LOOKASIDE      ?= https://src.fedoraproject.org/repo/pkgs/rpms/kernel
SERIES         ?= $(HERE)/series
PATCH_DIR      ?= $(HERE)/patches

.PHONY: srpm
srpm:
	@test -n '$(outdir)' || { echo 'usage: make -f copr.mk srpm outdir=DIR' >&2; exit 2; }
	@printf '%s\n' '$(DISTGIT_COMMIT)' | grep -Eq '^[0-9a-f]{40}$$' || \
		{ echo 'DISTGIT_COMMIT must be a full 40-hex commit id' >&2; exit 2; }
	@command -v git >/dev/null && command -v curl >/dev/null && \
		command -v rpmbuild >/dev/null || dnf -y install git-core curl rpm-build
	@set -eu; \
	outdir='$(abspath $(outdir))'; \
	mkdir -p "$$outdir"; \
	work=$$(mktemp -d); \
	trap 'rm -rf "$$work"' EXIT; \
	echo "== dist-git $(DISTGIT) at $(DISTGIT_COMMIT)"; \
	git clone -q --no-checkout '$(DISTGIT)' "$$work/kernel"; \
	git -C "$$work/kernel" checkout -q --detach '$(DISTGIT_COMMIT)'; \
	test "$$(git -C "$$work/kernel" rev-parse HEAD)" = '$(DISTGIT_COMMIT)'; \
	cd "$$work/kernel"; \
	if grep -Evq '^SHA512 \([A-Za-z0-9._+-]+\) = [0-9a-f]{128}$$' sources; then \
		echo 'sources: unexpected line (only SHA512 entries with plain file names)' >&2; \
		exit 1; \
	fi; \
	while read -r _ file _ sum; do \
		file=$${file#(}; file=$${file%)}; \
		echo "== lookaside $$file"; \
		curl -fsSL --retry 3 -o "$$file" '$(LOOKASIDE)'"/$$file/sha512/$$sum/$$file"; \
		printf '%s  %s\n' "$$sum" "$$file" | sha512sum -c --quiet -; \
	done < sources; \
	cp '$(HERE)/kernel-local' kernel-local; \
	: > linux-kernel-test.patch; \
	sed -e 's/#.*//' -e 's/[[:space:]]*$$//' -e 's/^[[:space:]]*//' '$(SERIES)' | \
		{ grep -v '^$$' || true; } > "$$work/series"; \
	while read -r patch; do \
		case "$$patch" in */* | .*) echo "series: bad entry $$patch" >&2; exit 1;; esac; \
		echo "== patch $$patch"; \
		cat '$(PATCH_DIR)'"/$$patch" >> linux-kernel-test.patch; \
	done < "$$work/series"; \
	cat '$(HERE)/apex-spec-header.inc' kernel.spec > kernel.spec.apex; \
	mv kernel.spec.apex kernel.spec; \
	rpmbuild -bs --define "_sourcedir $$PWD" --define "_specdir $$PWD" \
		--define "_srcrpmdir $$outdir" kernel.spec
