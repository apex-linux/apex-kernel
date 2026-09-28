# Apex kernel overlay

**Status: deferred to M2. Adoption gates per [ADR 0005](../../docs/adr/0005-kernel-fedora-fork.md).**
M1 ships Fedora's stock, Fedora-signed kernel. Nothing in this directory is built by CI
yet, and the audio fix for the stock kernel is the HDA patch firmware of
[ADR 0004](../../docs/adr/0004-audio-hda-patch-firmware.md), not a kernel patch.

The directory prepares a thin fork of Fedora's own kernel package: Fedora's dist-git at
a pinned commit, built in COPR, with changes made only through the hooks Fedora's
`kernel.spec` already has. It is kept here so that the M2 work starts from reviewed
pieces, and so the ALC294 quirk has one home until it goes upstream.

## Pieces

| File | Fedora hook | What it does |
|---|---|---|
| `apex-spec-header.inc` | prepended to `kernel.spec` | `buildid .1.apex` (release `300.1.apex.fc45`), `kcflags -march=znver3 -mtune=znver3`, no debug, selftests or efiuki variants; debuginfo stays on (the file says why) |
| `kernel-local` | `Source3001`, merged into every generated config | turns on `RCU_LAZY` + `RCU_NOCB_CPU_DEFAULT_ALL` and builds `CPU_IDLE_GOV_TEO`; pins the Fedora defaults Apex depends on, including `SND_HDA_PATCH_LOADER` and `SND_HDA_RECONFIG` |
| `series`, `patches/` | `linux-kernel-test.patch` (`Patch999999`, applied last with `git apply`, only when longer than 9 lines) | hardware fixes that are not upstream yet, concatenated in `series` order |
| `copr.mk` | COPR `make_srpm` | clones dist-git at `DISTGIT_COMMIT`, verifies every lookaside source against its SHA512, drops the three inputs above in and runs `rpmbuild -bs` |

How they fit:

```
Fedora dist-git kernel.git @ DISTGIT_COMMIT (pinned, 40 hex)
  + lookaside sources (sha512 from that commit's `sources`)
  + kernel-local                        -> configs (process_configs.sh -w -n -c)
  + series -> linux-kernel-test.patch   -> applied after Fedora's redhat patch
  + apex-spec-header.inc + kernel.spec  -> buildid, kcflags, variants
  = kernel-7.2.7-300.1.apex.fc45.src.rpm  (copr.mk)  -> COPR fedora-45-x86_64
```

`series` has the same format as `packaging/libfprint/series`: one file name per line
from `patches/`, `#` for comments. The ALC294 quirk
(`0001-ALSA-hda-realtek-Fix-speaker-output-on-ASUS-M7400QC.patch`) is listed but
commented out. Its message has blanks for the COEF values, and a "TODO before sending"
block below the `---` line (which `git am` drops) lists what must happen before it is
sent upstream or enabled here. The diff applies without fuzz to v7.2.7 and to Fedora's
7.2.7 tree (Fedora's `patch-7.2-redhat.patch` does not touch `sound/`), which matters
because `kernel.spec` applies patches with `git apply`.

## Building an SRPM by hand

As root in a Fedora 45 container or in the builder VM
([ADR 0013](../../docs/adr/0013-build-pipeline.md)):

```bash
make -f packaging/kernel/copr.mk srpm outdir="$PWD/target/kernel-srpm"
```

`DISTGIT_COMMIT` must be Koji's source commit of the Fedora build being followed:

```bash
koji buildinfo kernel-7.2.8-300.fc45 | grep ^Source
```

Wiring it to COPR later takes a two-line `packaging/kernel/.copr/Makefile` containing
`include $(dir $(lastword $(MAKEFILE_LIST)))../copr.mk`, and a package with
`--method make_srpm --subdir packaging/kernel`. That file is not created on purpose:
nothing may build this kernel before the gates below hold.

## Adoption gates (ADR 0005)

The image switches from Fedora's kernel to this one only when all of these hold:

1. **Measured benefit.** Power (idle and video playback on battery) and latency
   measurements on the laptop show an improvement over the stock kernel.
2. **Automatic rebase.** A bot bumps `DISTGIT_COMMIT` for every Fedora 45 stable kernel
   and rebuilds.
3. **Automatic fallback.** The image uses the stock Fedora kernel whenever this kernel
   lags Fedora by more than 72 hours, or when Bodhi marks the Fedora kernel update as a
   security update.
4. **Locked supply chain.** Kernel NEVRAs and RPM sha256 sums are locked in the
   repository and changed only by reviewed PRs; CI checks that the COPR build's source
   commit is the pinned one; the COPR signing key is committed (`gpgkey=file://`) and
   its fingerprint checked.
5. **One kernel in the compose.** `excludepkgs=kernel*` on every Fedora repository for
   fork builds, so the compose cannot mix the two.

Also at adoption: the VM qualification runs with `-cpu host` (the build targets Zen 3),
and the MOK decision of [ADR 0012](../../docs/adr/0012-trust-and-keys.md) must be taken
first if Secure Boot is to stay on.

## Updating

- **New Fedora kernel:** set `DISTGIT_COMMIT` to Koji's source commit, check that every
  enabled patch still applies (`git apply --check` on the new tree), and list where
  `kernel-local` now differs from Fedora's config in that commit:

  ```bash
  grep -E '^(CONFIG_|# CONFIG_)' packaging/kernel/kernel-local |
    while read -r l; do grep -qxF "$l" kernel-x86_64-fedora.config || echo "differs: $l"; done
  ```

  Only the deliberate changes (`RCU_LAZY`, `RCU_LAZY_DEFAULT_OFF`,
  `RCU_NOCB_CPU_DEFAULT_ALL`, `CPU_IDLE_GOV_TEO`) should appear. A pinned default that
  shows up means Fedora changed it: `kernel-local` silently keeps Apex's value, so decide
  in the PR whether to follow Fedora. The build itself fails only when a pinned value
  becomes impossible (process_configs.sh reports a mismatch).
- **A patch reaches Fedora:** remove it from `series` and `patches/` (check with
  `git log v7.2.7..<fedora tag> -- <file>` in the kernel tree).
