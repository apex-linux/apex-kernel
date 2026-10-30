# kernel-cachyos and NVIDIA's open modules, built as one pair

The CachyOS kernel (GCC build) rebuilt from the COPR's signed SRPM, and negativo17's
`nvidia-kmod` built for exactly that kernel in the same job, both signed with one key
that lives only for that job ([ADR 0015](https://github.com/apex-linux/apex/blob/main/docs/adr/0015-cachyos-kernel-and-nvidia.md),
[ARCHITECTURE 4.2](https://github.com/apex-linux/apex/blob/main/docs/ARCHITECTURE.md#42-kernel-and-nvidia-lane-s1c)). apex-image's
`apex-lane` has the pair kind (`source=copr-srpm`) that runs the pair job. This
directory holds what the K1 spike proved, the job's scripts and its pins, and `pkg.env`
makes the pair the `kernel-cachyos` family of `apex-lane` and `image.sh`.

| File | Role |
|---|---|
| `kernel-spec.patch` | ADR 0015 §1's build-mechanics hunks, made against the 7.3.0-4 spec: `Release: %{_cachyos_release}.cachyos1.apex%{apex_release}%{?dist}`; `_disable_source_fetch 1`; after `%autopatch`, the patches `series` names, with `patch -p1 --fuzz=0`; `MODULE_SIG_KEY` names the job's key; core `%posttrans` and modules `%posttrans` reduced to `depmod -a`, core `%preun` dropped. The defines `apex_release`, `apex_series` and `apex_module_sig_key` are each required: the spec does not parse without them |
| `series` | the patches applied after the CachyOS ones, one file name per line relative to `series`; empty today. The spec's `%prep` first runs `test -r` on it: a missing series file would otherwise pass unseen through the `sed \| while` pipe that applies it |
| `tests/fixtures/` | the 7.3.0-4 SRPM's `kernel-cachyos.spec` (sha256 `0edf6e56…`), which the selftest patches with `kernel-spec.patch` |
| `module-key.sh` | `generate DIR CN`: an ECDSA P-384 key and its certificate on a tmpfs, the kernel's own certificate extensions; `shred DIR`: the private key goes, the DER certificate stays |
| `kmod-build.sh` | in the container that built the kernel: installs its `kernel-cachyos-devel` and dwarves, puts `VMLINUX` (the kernel's `vmlinux`) into its tree so the modules get BTF, checks the GCC major, rebuilds the `nvidia-kmod` SRPM unmodified with `--define 'kernels <uname -r>'` and kmodtool's signing macros |
| `pair.sh` | the pair job, run as root in one fresh `fedora:45` container: verifies every pinned input of the mirror, makes the key, builds the kernel (ccache when `CCACHE_DIR` is set) and the kmod, shreds the key, runs `check.sh`, writes `pair.lock`; [the contract below](#the-pair-job) |
| `bump.sh` | `bump.sh check`: `point`, `major … waiting-for-owner EOL-in-Nd` or `none` from the COPR and kernel.org, then the newest negativo17 builds of the pinned NVIDIA branch with their soak; `bump.sh nvidia-env`: the candidate `nvidia.env` of a driver bump, on stdout ([Driver bump](#driver-bump)); edits nothing |
| `source-check.sh` | `source-check.sh DIR`: checks a pair's public source set ([below](#the-public-source-set)); exit 1 names what is missing or wrong, exit 2 means it could not run |
| `check.sh` | the lane checks of a pair (the lane's `check.sh` contract, plus `MODULE_CERT`): `config-required.txt`, the certificate built into `vmlinuz`, the signer of every module, the NVIDIA signatures verified with `openssl cms` and a `.BTF` section in every NVIDIA module, `kernel-uname-r`, no private key in a payload |
| `config-required.txt` | the config lines ADR 0015 relies on, compared verbatim |
| `patches/` | the ALC294 quirk, out of any series (ADR 0015, section 8) |
| `pkg.env` | the lane's recipe: `source=copr-srpm`, `family=kernel-cachyos`, `install=` the kernel packages (the kmod built for that kernel joins them), and the two pin files `kernel_env` and `nvidia_env`; `KEY=VALUE`, never sourced |
| `kernel.env` | the COPR, chroot, SRPM NEVRA and sha256, the COPR key; the CachyOS tag, the repository it is verified from (`tag_repo`, the one K1 step 5 used) and its key, with the key's keys.openpgp.org URL (`tag_key_url`; keyserver.ubuntu.com serves the same key); `KEY=VALUE`, never sourced |
| `nvidia.env` | the `nvidia-kmod` SRPM and each userspace RPM with NEVRA and sha256, the negativo17 key, and `soak_days` (7; `bump.sh` uses 7 when the key is absent); the same format |

## The pair job

### Pins per Fedora release

`FEDORA` picks the release, in `pair.sh` and `bump.sh` alike; unset, it is 45, and the
jobs run exactly as before. Release 45 reads `kernel.env` and `nvidia.env` in this
directory; any other release reads `fedora-FEDORA/kernel.env` and
`fedora-FEDORA/nvidia.env`, and never falls back to 45's. Without that directory both
scripts stop with exit 2: "no fedora-46 pins: fedora-46/kernel.env and nvidia.env are
not both there". The pins must be that release's: `chroot` is `fedora-FEDORA-x86_64`,
the two SRPMs end in `.fcFEDORA.src`, every userspace RPM in `.fcFEDORA.x86_64` or
`.noarch`, and anything else is exit 2. `bump.sh` asks the COPR about that chroot and
negativo17's `fedora-FEDORA` repository. `kernel-spec.patch`, `series` and its patches
are shared. apex-image's `next` lane runs the pair job with `-e FEDORA=46` in a
fedora:46 container; there is no `fedora-46/` yet, because the COPR's F46 chroot and
negativo17's key for it are still to be chosen, the key by the owner (ROADMAP S6).

`APEX_RELEASE=N pair.sh MIRROR OUT [DNF-OPTION...]` follows the lane's `check.sh` contract: exit 1
holds the pair, with the reason on the last line; exit 2 means it could not run. A
reason that starts with `kmod:` is a kmod failure on a kernel that built, `kernel:` a
kernel failure, and `check:` a failed `check.sh`; the lane picks the hold (72 h or
14 days) from that.

- MIRROR holds the files `kernel.env` and `nvidia.env` pin, under their RPM file
  names, and the two key files `copr.gpg` and `negativo17.gpg`. Each key file must
  hold exactly its pinned key; each input must have its pinned sha256 and a signature
  that `rpmkeys -K` accepts against a keyring holding only its key. Anything else
  holds the pair before a key exists.
- The module key lives on the tmpfs `MODKEY_DIR` (`/run/apex-modkey` by default) and is
  shredded on every exit after it was made; a directory that is not empty is refused,
  and left alone.
- OUT gets `pair.lock` (`kernel=`, `kmod=` with their NEVRAs, `module_cert_sha256=`,
  one `rpm=FILE SHA256` per built RPM), the RPMs under `rpms/`, the certificate
  `signing_key.x509` and one log per stage.
- `OUT/timings` is the build-time report (K7), written on every exit once OUT exists:
  hold or success. `KEY=VALUE` lines, whole seconds, one per stage the job reached, in
  order (`verify`, `dnf`, `key`, `kernel_builddep`, `kernel`, `kmod`, `check`,
  `source`; each runs until the next starts, so `kmod` includes the shred), then
  `total` from the start of `pair.sh`. With `CCACHE_DIR`, `ccache_hits` (direct plus
  preprocessed), `ccache_misses` and `ccache_size_kib` follow, counted from a reset
  before the kernel build, so they cover this job's kernel and kmod. The lane renders
  the report; nothing here formats it.
- Once the kernel has built, whatever happens after, `OUT/debug/` holds the files the
  store keeps for a pair: `debug/vmlinux` (with DWARF, from the build tree),
  `debug/System.map`, `debug/config` (the built `.config`) and `debug/kernel.log` (the
  `rpmbuild -bb` output, there after a kernel failure too). `rpmbuild --noclean`
  leaves the tree for the copy; `pair.sh` then deletes it, before the kmod build.
  `-devel` is `rpms/kernel-cachyos-devel-*.rpm`. The other stage logs stay at the top
  of OUT.
- `vmlinux` must have a `.BTF` section (`readelf --section-headers`): the config line
  `CONFIG_DEBUG_INFO_BTF=y` says BTF was asked for, not that pahole wrote it. Without
  one the pair holds with "kernel: vmlinux has no .BTF section", and `OUT/debug/` is
  still kept. The COPR's 7.3.0-4 vmlinux, unpacked from its `vmlinuz`, carries a
  6.6 MB `.BTF`.
- A kmod failure still leaves a kernel the lane can ship as `degraded=nvidia`: after
  the shred, `check.sh` runs with `CHECK_SCOPE=kernel` (the kernel-side checks, any
  kmod RPM ignored, and `kernel-uname-r` from `kernel-cachyos-core`), and OUT gets
  `kernel.lock`, which is `pair.lock` without the `kmod=` line, and the kernel RPMs
  alone. The exit stays 1 with the `kmod:` reason. A failed kernel check gives a
  `check:` reason and no `kernel.lock`. On 2026-10-24 `CHECK_SCOPE=kernel` passed on
  the COPR's own 7.3.0-4 RPMs, with their built-in certificate as `MODULE_CERT`:
  6,553 in-tree modules signed (7.2.8 had 6,491).
- The selftest runs it against fake rpm tools, a fake kmod build and a fake
  `check.sh`. On 2026-10-24 it also ran in a `fedora:45` container on the real mirror
  of 7.3.0-4 and 615.78.08 up to `rpmbuild -bb`, which was stubbed: the inputs
  verified, the key was made, `kernel-spec.patch` applied and the BuildRequires
  installed, and the stub's failure held the pair with only the certificate left on
  the tmpfs. A whole pair has not run through `pair.sh`; that waits for the builder
  VM, whose disk the kernel build needs.

## The public source set

ADR 0015 gives each public image digest a source artifact for the GPL kernel and open
modules (ROADMAP N6). `pair.sh` writes it to `OUT/source/` for every pair it builds,
the kernel-only pair of a kmod failure included, and runs `source-check.sh` on it before
any lock exists: a set that does not check holds the pair with a `source:` reason.

| Path | Holds |
|---|---|
| `srpms/` | the kernel and nvidia-kmod SRPMs, the mirror's files under their RPM names, the same bytes `pair.sh` verified |
| `recipe/` | `kernel-spec.patch`, `series`, every patch the series names (at its series-relative path), `kernel.env`, `nvidia.env` |
| `licenses/` | the kernel's `COPYING` and `LICENSES/preferred/GPL-2.0` as `kernel-COPYING` and `GPL-2.0`, taken from the build tree; nvidia-kmod's `COPYING` (MIT and GPL-2.0, at the top of its source tarball; the spec's `License:` reads "NVIDIA License" and ships no `%license` file), or `nvidia-kmod-COPYING.note` naming where it is when it cannot be extracted |
| `README.source` | the kernel and kmod NEVRAs (`kmod=none: …` after a kmod failure), `tag`, `tag_repo`, `apex_release`, the two SRPMs, and how to rebuild: `rpm -i` the kernel SRPM, apply `kernel-spec.patch`, `rpmbuild -bb` with the three defines (the spec applies the series in order), then the kmod for that kernel |
| `SHA256SUMS` | every other file of the set, `sha256sum` format, paths relative to the set |

`source-check.sh` checks, in this order, and names the first failure: the recipe and
every series entry; exactly the two pinned SRPM names in `srpms/`, each with its pinned
sha256; the licences; `README.source`; then that `SHA256SUMS` lists every file, no more,
and matches. On 2026-10-24 it passed on a set of the real 7.3.0-4 and 615.78.08 SRPMs
with the pins of this directory, and refused it after one changed byte.

What apex-image consumes: the directory `OUT/source/` as it is, checked with
`source-check.sh`. Publishing it next to an image digest, as an OCI artifact that refers
to the digest, is apex-image's (`apex-lane sources`), with the owner's keys; nothing
here publishes.

`APEX_PAIR_FAULT=kmod` is a test hook, for the lane's rehearsal of an injected kmod
failure: the kmod build fails without running and the job takes the kmod-failure path
above (exit 1, `kmod:`, `kernel.lock`). Unset or empty it does nothing, any other value
exits 2, and the builder VM never sets it.

When a point and a major bump both exist, `bump.sh check` prints both, the point first:
the lane takes the point unattended, and the major line keeps the owner's EOL countdown
in view. The pinned major's EOL counts 0 days once kernel.org lists it as EOL
or drops it, and otherwise 16 days after the next major's release (ROADMAP's 7.1 and
7.2), or `unknown` when releases.json no longer shows that date.

## Driver bump

ROADMAP N8. `bump.sh` makes the data side mechanical; the owner's laptop run stays a
person's. In order:

1. `bump.sh check` prints `nvidia NEVRA SHA256 newer soaking-Nd` for a newer build of
   the pinned branch, and `newer soaked` once its repodata build time is `soak_days`
   (`nvidia.env`, 7 when absent) old. A new branch is not offered: a branch change is
   a pin edit by hand, for the owner.
2. When every newer line reads `soaked`, `bump.sh nvidia-env` prints the candidate
   `nvidia.env`: `kmod_srpm`, `kmod_srpm_sha256` and each `userspace` line moved to the
   newest build of the branch, every other line as it was. It refuses, with exit 1 and
   the reason on the last line, while a package is missing, still soaking, older than
   its pin, or of another driver version than the kmod.
3. The lane's bump PR writes that output to `nvidia.env` unchanged; the selftest checks
   it like any pin.
4. The whole pair rebuilds: a driver bump rebuilds the kernel too, from a warm ccache
   (ARCHITECTURE 4.2).
5. The owner runs ACCEPTANCE §4 from the staged deployment on the laptop.
6. Then the image publishes. That the Flathub `GL.nvidia` extension of the same version
   exists is `apex-flatpak-update`'s check (ROADMAP S1d), not this one's.

## K1, 2026-10-02

Steps 1 to 4 of the roadmap's K1 ran in the builder VM (8 vCPUs, 6 GiB, Fedora 45,
`podman` as root, containers of `image/Containerfile`'s `REPOS_BASE`
`fedora@sha256:1e13e11f…`, repositories `fedora` and `updates` only). Step 5, the same
builds on Linux 7.3.0, ran on 2026-10-24 ([below](#k1-step-5-2026-10-24)). Every number below comes from a saved
command output; the commands and their outputs are in the logs of the spike and of its
verification, kept outside the repository.

### Inputs

| Input | Value |
|---|---|
| Kernel SRPM | `kernel-cachyos-7.2.8-cachyos2.fc45.src.rpm`, COPR build 11055625, chroot `fedora-45-x86_64` (succeeded 2026-09-30 18:06 UTC), 259,849,829 bytes |
| sha256 | `70c92dee5fbefeb58487852acd967bc577a8b9a9af0b0e26c16b81e99445c6b9`, equal to the chroot repodata |
| Its sources | `cachyos-7.2.8-1.tar.gz` `9030fb2f…`, `config` `3df33112…`, `0001-bore-cachy.patch` `1809a4d4…`, spec `94ec12d0…` |
| COPR key | `537D EED3 3436 B036 7F5B 26D5 B3E3 132C F108 59CF`, RSA 2048, expires 2028-01-23, from `https://download.copr.fedorainfracloud.org/results/bieszczaders/kernel-cachyos/pubkey.gpg` |
| `rpmkeys -Kv` | header and legacy RSA/SHA256 signatures OK against a keyring holding only that key; an empty keyring refuses the file |
| kmod SRPM | `nvidia-kmod-3:615.71.09-2.fc45.src.rpm`, sha256 `c3862ac60c6e2ea96c29bbac4cfe036742ac26e4d36c1fff2252a69ab889c453`, RSA/SHA512 signature OK |
| negativo17 key | `0C5D 0F47 0484 AE2F C40A 9B65 97F3 0089 93E8 909B`, RSA 4096, expires 2029-08-31, from `https://negativo17.org/repos/RPM-GPG-KEY-slaanesh` |
| Userspace (newest in `fedora-nvidia`, each signature OK, sha256 equal to the repodata) | `nvidia-driver`, `-common`, `-cuda`, `-cuda-libs`, `-libs` 3:615.71.09-5; `nvidia-kmod-common` 3:615.71.09-2; `nvidia-modprobe` 3:615.71.09-1; `nvidia-persistenced` 3:615.71.09-3; `nvidia-driver-selinux` 0.1-3 |

Both fingerprints equal the ones ADR 0015 recorded on 2026-09-28. Neither key is on
keys.openpgp.org or keyserver.ubuntu.com, so the second-source check the ADR asks for
before pinning is still open. The SRPMs, keys, sha256 files, the COPR build id and the
userspace RPMs are mirrored in the VM under `~/apex-store/mirror/`.

### Build cost

The SRPM rebuilt unmodified with `rpmbuild --rebuild` in a fresh container, twice, with
ccache on `PATH` (`/usr/lib64/ccache`, a podman volume, no spec change). Then the pair
job: `kernel-spec.patch`, the tmpfs key, the kernel with `rpmbuild -bb`, the kmod, the
shred and `check.sh`, in one fresh container.

| | Cold | Warm | Pair: kernel | Pair: kmod |
|---|---|---|---|---|
| Wall (`time -v`) | 1:27:00 | 14:13 | 33:04 | 3:07 |
| CPU | 747 % | 536 % | 682 % | 598 % |
| `-j` | 8 (`RPM_BUILD_NCPUS`, 8 vCPUs) | 8 | 8 | 8 |
| Peak RSS of one process (`time -v`) | 3,092,516 kB | 3,092,364 kB | 3,092,644 kB | 288,376 kB |
| Peak anonymous memory of the container (5 s samples) | 2.66 GB | 3.17 GB | 3.17 GB (whole job) | |
| Lowest `MemAvailable` in the VM | 2,750,200 kB | 2,175,704 kB | 2,860,468 kB (whole job) | |
| Most swap in use in the VM (zram, 5 s samples) | 11 MB | 25 MB | 46 MB (whole job) | |
| The container's `memory.swap.peak` | 12.5 MB | 165 MB | not recorded | |
| OOM kills | 0 | 0 | 0 | 0 |
| ccache hits | 146 of 25,896 (0.6 %) | 25,889 of 25,896 (99.97 %), all direct | 25,889 of 25,896, 98.7 % through the preprocessor | 1,226 of 2,857 |
| Scratch: peak of the rpmbuild tree (`du`, apparent) | 34.2 GB | 34.2 GB | 34.1 GB | |
| Scratch: peak growth of the VM's btrfs | 18.5 GB (ccache included) | 14.7 GB | 14.2 GB (whole job) | |

The ccache volume holds 4.3 GB after the cold build. The whole pair job, from `dnf` to
`check.sh`, took 2,232 s; `check.sh` alone 8 s. The COPR's fedora-45 chroot built the
same SRPM in 117 minutes at `-j4`. Against the ADR's estimates: the cold build is at the
top of 45–90 min, a warm one beats 20–45 min, and the kmod is within 3–5 min.

The first pair's kernel ran at the speed of ccache's preprocessor mode: the key path
changed `include/generated/autoconf.h`, so no direct-mode entry matched. The path stays
`/run/apex-modkey/signing_key.pem`, and a second pair job, with a new key, measured the
steady state:

| Second pair job | |
|---|---|
| Kernel (`rpmbuild -bb`) | 14:55, ccache 25,889 of 25,896 hits, all direct |
| kmod | 1:26, ccache 2,759 of 2,857 hits |
| `check.sh` | 8 s; a new certificate, and all 6,496 modules signed with it |
| Whole job | 1,033 s (17 min) |
| Memory | container anonymous peak 3.11 GB, VM `MemAvailable` never below 2,860,496 kB, 34 MB of zram |

S1c's exit asks for a cold pair in at most 2 h and a warm one in at most 1 h. The warm
pair took 17 min. No cold pair ran as one job; the cold kernel (1:27:00) and the first,
cold kmod (3:07) add up to about 1 h 31 min.

### Memory: `-j6` at 6 GiB, or a 10 GiB VM

Decision: neither. Kernel jobs run at the default `-j8` in the 6 GiB builder VM.

- At `-j8` the container's anonymous memory peaked at 3.17 GB and the largest single
  process at 3,092,644 KiB. The VM's 5 s samples never showed less than 2,175,704 kB
  available nor more than 46 MB in zram, in any of the four builds; the container's own
  `memory.swap.peak`, recorded in the two unmodified builds, reached 165 MB in the warm
  one. Nothing was killed. `-j6` would only make it slower.
- The host is the constraint. During the cold build, with the owner's 4 GiB desktop VM
  running, the host's `MemAvailable` fell to 982,572 kB and its swap use rose to
  4,733,144 kB of 7,614,460 kB (30 s samples). The builder VM's RSS sat at about 6 GiB,
  because the guest's page cache fills it. A 10 GiB builder VM does not fit next to the
  desktop VM.
- The desktop VM stopped between 21:21 and 22:06 UTC (the last host sample that shows it
  and the first that does not), before the warm build; the spike did not touch it. From
  then on the host kept at least 3,778,028 kB available.

### The built kernel's config

Every line of `config-required.txt` is in the built config of all four builds: module
signing with ECDSA and SHA-512, `SYSTEM_TRUSTED_KEYS=""`, lockdown built in and forced to
none, `CONFIG_LSM="lockdown,yama,integrity,selinux,bpf,landlock"`, `IMA_ARCH_POLICY`,
BORE, `SCHED_CLASS_EXT`, `PREEMPT_DYNAMIC`, HZ 1000, x86-64-v3, BTF, amd-pstate default
mode 3, the HDA patch loader with `RECONFIG`, `HWDEP` and `ALC269=m`, and EROFS, overlayfs
and dm-crypt as modules.

What differs from the SRPM's `config` comes from the spec's `%prep` and from
`olddefconfig` with GCC and without rustc: `CACHY`, `SCHED_BORE`, HZ 1000, x86-64-v3,
the IMA options and the LSM list are set by the spec; `CONFIG_RUST=y` is gone with its
symbols, as in the COPR build ADR 0015 read, and no driver goes with it, because the
SRPM's `config` enables none that needs Rust (`NOVA_CORE` and `DRM_NOVA` are not set
there); `LTO_NONE` replaces the source's clang LTO symbols; `CONFIG_CC_VERSION_TEXT` is
`gcc (GCC) 16.2.1 20260819 (Red Hat 16.2.1-2)`.

Facts the ADR does not name: `CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"` (the
autogenerated key) unless the spec patch sets it; `SECONDARY_TRUSTED_KEYRING=y`,
`INTEGRITY_MACHINE_KEYRING=y`; `MODULE_DECOMPRESS=y` with zstd; `KEXEC_SIG=y` not forced;
IMA's default hash is SHA-1; `DRM_NOUVEAU=m`.

### The compose

A copy of `image/Containerfile` built the test image in the builder VM; the production
inputs were not changed. Its delta: the nine Fedora kernel names joined the `excludepkgs`
line of `fedora` and `updates`; two local repositories, the spike's own RPMs
(`gpgcheck=0`) and the mirrored negativo17 binaries (`gpgcheck=1` with the negativo17
key); `--install kernel-cachyos kernel-cachyos-core kernel-cachyos-modules` (and the kmod
and `nvidia-kmod-common`) and `--no-initramfs`; in the final stage `depmod -a` before
dracut, the NVIDIA modules in `--omit-drivers`, and the kargs `module.sig_enforce=1`,
`zswap.enabled=0` and `module_blacklist=nouveau,nova_core`. Five minimal composes
settled the unknowns of the risk table:

- **The kernel Provides.** The minimal manifest asks for `kernel`. With the Fedora names
  excluded it resolves to `kernel-cachyos-core` and `-modules` through their
  `Provides: kernel`, `kernel-modules-uname-r` and the rest; `--install kernel-cachyos`
  adds only the meta package. Either exclusion works alone: the repositories'
  `excludepkgs` or build-rootfs `--exclude`. With neither, both kernels install and
  rpm-ostree stops: "Multiple kernels (vmlinuz) found".
- **The COPR `%posttrans`.** No spec change is needed. `/boot` stays empty, no BLS entry,
  no `symvers` copy, no `/etc/kernel` change. `nvidia-kmod-common`'s `%post`
  (`nvidia-boot-update post`) printed nothing and left neither `/etc/default/grub` nor
  `/etc/kernel/cmdline`. Both scripts skip their work when `/run/ostree-booted` exists.
  Without it, and with neither file present, `nvidia-boot-update` prints "no bootloader
  configured"; the compose log shows other scriptlets' output but not that line, so the
  scriptlet saw `/run/ostree-booted`.
- **dracut order.** With `--no-initramfs` rpm-ostree runs no dracut and still leaves a
  complete `modules.dep`; the final stage's `depmod -a` then dracut builds the only
  initramfs. Without the flag rpm-ostree's own dracut also worked on this kernel, and the
  final stage then builds a second one over it.
- `bootc container lint --fatal-warnings` with the empty `lint-skips.txt`: 14 passed,
  1 skipped by bootc itself, in the four probe composes that succeeded and in both test
  images (the fifth stops at "Multiple kernels" first). Every G1 check passed unchanged,
  `kernel.sh` included (it accepts `module_blacklist=`).
- The image with the pair and the NVIDIA modules is 3.48 GB, against 3.44 GB for the
  production image of the same day with Fedora's kernel. Of the NVIDIA set it holds only
  `kmod-nvidia`, `nvidia-kmod-common`, `nvidia-modprobe` and `nvidia-driver-selinux`: the
  userspace was mirrored and verified, not composed.

### The NVIDIA modules

NVIDIA 615.71.09 (negativo17 `-2`, with its two Anatase patches) builds on
7.2.8-cachyos2 with GCC 16.2.1 in 3 minutes. The kmod RPM is
`kmod-nvidia-7.2.8-cachyos2.fc45.x86_64-3:615.71.09-2.fc45`; it requires
`kernel-uname-r = 7.2.8-cachyos2.fc45.x86_64` and `nvidia-kmod-common >= 3:615.71.09`,
and its five modules are xz-compressed under `/lib/modules/<uname -r>/extra/nvidia/`.
`nvidia-kmod-common` pulls in only `nvidia-modprobe` and, with SELinux,
`nvidia-driver-selinux`.

- `modinfo`: `vermagic: 7.2.8-cachyos2.fc45.x86_64 SMP preempt mod_unload`, signer
  `Apex kernel 7.2.8-cachyos2.fc45.x86_64 k1`, `sig_key`
  `5C:E6:B2:1A:2F:9C:13:4F:62:EF:3E:6C:94:D0:DE:B3:AD:FA:D5:72` (the serial of the job's
  certificate), `sig_hashalgo: sha256`.
- `check.sh`: the certificates built into `vmlinuz` are exactly the job's certificate
  (SHA-256 fingerprint `79:92:52:71:…:4A:3D:73:C6`); 6,496 modules (6,491 in-tree, 5
  NVIDIA) name it as signer; the five NVIDIA signatures verify against it.
- After `shred`, only `signing_key.x509` was left on the tmpfs.

### Qualification

`qualify.sh local` ran twice from a copy of the checkout with one change: its G4 key
names `kernel-cachyos-core` instead of `kernel`. The repository's own script fails on
this image, because `rpm -q kernel` finds no package of that name ("cannot compute the
G4 key").

| Image | Result |
|---|---|
| The unmodified cold rebuild, no NVIDIA | 29 rows PASS, no SKIP or WARN, 1,133 s |
| The pair, with the NVIDIA modules and `nvidia-kmod-common` | 29 rows PASS, no SKIP or WARN, 1,186 s |

Booting the kept disk of the second run again showed:

- SELinux enforcing; `module.sig_enforce` `Y`; lockdown `none`; zswap off; BORE on; full
  preemption; taint 0 after boot. The one built-in certificate is the job's, and all
  59 loaded modules carry its signature. An unsigned copy of `dummy.ko` is refused
  ("Key was rejected by service"); the signed one loads.
- Journal lines of AVC denials over the nine boots on the disk: 138 (one denial can
  appear twice, through the audit transport and as a rate-limited kernel copy), of four
  kinds (systemd-logind reading the unlabeled `/boot/efi`, `chcon` asking for
  `mac_admin` from `tuned_t` and `unconfined_service_t`, and gnome-session-init-worker's
  `status`). The production G4 run with Fedora's kernel logged the same four kinds. None
  concerns modules (`module_load`, `module_request`, `sys_module`). The policy has no
  dontaudit rule for `module_load`, allows `module_request` to every domain while the
  boolean below is on, and dontaudits `sys_module` for many domains, which the search
  cannot see.
- Every AVC line in the saved journals of both G4 runs says `permissive=0`: the G4
  boots were enforcing. `qualify.sh` itself does not check the SELinux mode.
- `domain_kernel_load_modules` is on by default in `selinux-policy-targeted-45.19-1`,
  in both images. Turned off persistently and rebooted: the same 59 modules load, GDM's
  greeter comes up, and no module-related denial is logged. The boolean can stay at
  Fedora's default; nothing in the pair depends on it.
- The NVIDIA files are labelled `modules_object_t`, and negativo17's `nvidia-driver`
  policy module is installed.
- `modprobe nvidia`: the signature is accepted under `sig_enforce`, the module taints
  the kernel as out-of-tree (`O`, 4096), and its init fails with "NVRM: No NVIDIA GPU
  found" (ENODEV), so nothing stays loaded.

What the run cannot show, because the guest has no NVIDIA GPU: that the modules probe
the GA107, load the GSP firmware, bring up DRM/KMS and UVM, reach RTD3 and D3cold, and
survive s2idle. Those are the laptop rows of `docs/hardware/ACCEPTANCE.md` (K3).

## K1 step 5, 2026-10-24

Steps 1 and 3 again, on Linux 7.3.0, in a cloud container instead of the builder VM:
4 vCPUs, 15 GiB, Docker as root, `fedora:45` of the day
(`fedora@sha256:322dd035…`, not `REPOS_BASE`), repositories `fedora` and `updates` only.
Step 1's two rebuilds did not run: K1's rpmbuild tree peaked at 34.2 GB and the
container had 29 GB free. The kernel build stays a builder-VM job. Every number below
comes from a saved command output, kept outside the repository. `kernel.env` and
`nvidia.env` pin exactly these inputs.

### Inputs

| Input | Value |
|---|---|
| Kernel SRPM | `kernel-cachyos-7.3.0-4.cachyos1.fc45.src.rpm`, COPR build 11199225, chroot `fedora-45-x86_64` (succeeded 2026-10-23 18:16 UTC, the whole build at 19:54), 263,558,722 bytes |
| sha256 | `e6b57189499ce41b78255deadc86f38e318e24e895283b7e1f412a23de9cf49f`, equal to the chroot repodata |
| Its sources | `cachyos-7.3.0-4.tar.gz` `022eb75c…`, `config` `81fb56fe…`, `0001-bore-cachy.patch` `0682dfd0…`, spec `0edf6e56…` |
| Devel RPM | `kernel-cachyos-devel-7.3.0-4.cachyos1.fc45.x86_64.rpm`, 19,488,083 bytes, sha256 `f9c8539d…`, equal to the chroot repodata |
| `rpmkeys -Kv` | both files: header and legacy RSA/SHA256 signatures OK against a keyring holding only the COPR key (same fingerprint, same URL); an empty keyring gives `NOKEY` and exit 1 |
| CachyOS tag | `cachyos-7.3.0-4` (commit `6f1d9031…`, tagged 2026-10-23 13:14 UTC): `git verify-tag` gives `VALIDSIG` for `E8B9 AA39 F054 E30E 8290 D492 C3C4 8208 57F6 54FE` alone; its `git archive` and the SRPM's Source0, both uncompressed, are byte-identical (`9478fd17…`) |
| kmod SRPM | `nvidia-kmod-3:615.78.08-1.fc45.src.rpm`, the newest (negativo17 still has 615.71.09-2), 25,855,682 bytes, sha256 `2a16e83c24605b0f3c436caacb133c7b1b7724b105ed7c970ddf1a6809668532`, equal to the repodata; RSA/SHA512 signature OK against the negativo17 key alone, refused by an empty keyring. The same two Anatase patches; its spec equals negativo17/nvidia-kmod `52070eb` |
| Userspace (newest in `fedora-nvidia`, each signature OK, sha256 equal to the repodata) | `nvidia-driver`, `-common`, `-cuda`, `-cuda-libs`, `-libs`, `nvidia-kmod-common`, `nvidia-modprobe`, `nvidia-persistenced` 3:615.78.08-1; `nvidia-driver-selinux` 0.1-3 |

What changed in the packaging:

- The release now starts with the CachyOS tag number: `Release:
  %{_cachyos_release}.cachyos1%{?dist}`, `_cachyos_release 4`. `uname -r` is
  `7.3.0-4.cachyos1.fc45.x86_64`. The first 7.3.0 build (11177829, 2026-10-20) was still
  `7.3.0-cachyos1`; rpm sorts `4.cachyos1` above it.
- `kernel-spec.patch` applies to the new spec with `--fuzz=0` (offset −2 lines).
- The COPR's chroot built the kernel at `-j32` in 16 minutes (7.2.8: 117 minutes at
  `-j4`), with GCC 16.2.1-2.fc45.1 and dwarves 1.32.

### The config

`config-required.txt` against the SRPM's `config`, verbatim: 24 of its 29 lines match.
The five that do not are the ones the spec's `%prep` sets, as in 7.2.8:

| Line | The SRPM's `config` |
|---|---|
| `CONFIG_LSM="lockdown,yama,integrity,selinux,bpf,landlock"` | `CONFIG_LSM="landlock,lockdown,yama,integrity,bpf"` |
| `CONFIG_IMA_ARCH_POLICY=y` | absent |
| `CONFIG_SCHED_BORE=y` | `# CONFIG_SCHED_BORE is not set` |
| `CONFIG_HZ=1000` | `CONFIG_HZ=300` |
| `CONFIG_X86_64_VERSION=3` | `CONFIG_X86_64_VERSION=1` |

The COPR's built config (the `.config` in `-devel`) holds all 29. As in 7.2.8:
`CONFIG_RUST=y` in the source and gone from the build, no `NOVA_CORE` or `DRM_NOVA`,
`LTO_NONE`, `CONFIG_CC_VERSION_TEXT` `gcc (GCC) 16.2.1 20260819 (Red Hat 16.2.1-2)`,
`MODULE_SIG_KEY="certs/signing_key.pem"`, `ZSWAP_DEFAULT_ON=y`, `DRM_NOUVEAU=m`.

### The NVIDIA modules

NVIDIA 615.78.08 (negativo17 `-1`) builds on 7.3.0-4.cachyos1 unmodified, through
`kmod-build.sh` with the COPR's `-devel`. The GCC check passed (`CONFIG_GCC_VERSION`
160201, the container's `gcc-16.2.1-2.fc45.1`). The kmod RPM is
`kmod-nvidia-7.3.0-4.cachyos1.fc45.x86_64-3:615.78.08-1.fc45`, 10,120,616 bytes; it
requires `kernel-uname-r = 7.3.0-4.cachyos1.fc45.x86_64` and
`nvidia-kmod-common >= 3:615.78.08`, and holds the same five xz-compressed modules.

- `modinfo`, all five: `vermagic: 7.3.0-4.cachyos1.fc45.x86_64 SMP preempt mod_unload`,
  signer `Apex kernel 7.3.0-4.cachyos1.fc45.x86_64 k1s5`, `sig_key`
  `33:FA:2B:57:36:6D:77:6B:50:7D:87:BD:68:60:9E:A7:67:72:A3:DD` (the serial of the
  throwaway certificate), `sig_hashalgo: sha256`. After `shred`, only
  `signing_key.x509` was left on the tmpfs.
- `kmod-build.sh` (dnf, builddep and rpmbuild, no ccache): 6:19.94 wall at 282 % CPU,
  `-j4`, peak RSS 288,756 kB. K1's cold kmod took 3:07 at `-j8` in the builder VM.
- No errors. The warnings: 11,669 objtool lines "'naked' return found in
  MITIGATION_RETHUNK build", all in `nvidia.o`, in the RM core that NVIDIA's own
  makefile compiles; four `-Wformat` (`uvm_migrate_pageable.c:832-833`,
  `uvm_processor_id_t` for `%d`) and three `-Wunused-but-set-variable`
  (`nvkms-evo.c:370`, `nvt_edidext_861.c:1027` and `1029`); and "pahole version
  differs", because `nvidia-kmod` does not BuildRequire dwarves, so the NVIDIA modules
  carry no BTF. (Since then `kmod-build.sh` installs dwarves and gets the kernel's
  `vmlinux`, and the modules carry BTF: [below](#what-s1c-must-do).)
- Control: the same SRPM on the COPR's `kernel-cachyos-devel-7.2.11-cachyos1`
  (signature OK) in the same kind of container gives the identical set: 11,669 objtool
  lines, the same seven compiler warnings and the pahole line, in 5:35.06. Nothing is
  new with 7.3; no API of the new major breaks the build.

### A second source for the keys

- **COPR key.** Fedora 45's `distribution-gpg-keys-copr-1.123-1.fc45`, installed from
  `fedora` with dnf's signature check, ships `copr/copr-bieszczaders-kernel-cachyos.gpg`
  byte-identical to the pubkey URL's file (sha256 `04d4284d…`). In
  rpm-software-management/distribution-gpg-keys it arrived on 2023-01-30 ("update copr
  keys", by a COPR maintainer) and never changed. Another channel, with a Fedora
  signature, and in place since 2023; the origin is still COPR, whose team exports the keys.
- **CachyOS tag key.** keys.openpgp.org and keyserver.ubuntu.com serve the same
  fingerprint, uid `Peter Jung <admin@ptr1337.dev>`, the primary key valid until
  2028-03-31 (its encryption subkey expired on 2026-09-24; tags are signed by the
  primary). The key signs the tag above. GitHub's profile key endpoint is not reachable
  from the container.
- **negativo17 key.** Still none. keys.openpgp.org: 404 by fingerprint and by e-mail.
  keyserver.ubuntu.com: 404 by fingerprint; by e-mail, two older keys of the same
  person (`D495 00D3 43BB D8C2 98EC 0E79 7265 DCE4 0D61 C616`, RSA 3072, 2023, and a
  2008 DSA key), neither of which certifies `0C5D…909B`. pgp.mit.edu: 503.
  `distribution-gpg-keys` holds only the same person's COPR keys. The 50 newest commits
  of negativo17/nvidia-kmod are unsigned, and it has no tags.

## What S1c must do

- Poll the COPR per chroot. The builds of 7.2.5 to 7.2.8 are all `failed` overall (for
  the last two, because their epel-9 chroot failed), so the package's
  `latest_succeeded` is still 7.2.3; the state that counts is that of the
  `fedora-45-x86_64` build-chroot.
- Fetch the signed SRPM from the chroot repository (`Packages/k/<nvr>.src.rpm`, a
  redirect to Pulp storage; the result directory lists no RPMs any more), compare its
  sha256 with the chroot repodata, then `rpmkeys -K` against the COPR key alone. The
  `srpm-builds/<id>/` SRPM has the same payload and no signature.
- Mirror at first sight. Within the week after ADR 0015 was written, negativo17's
  `nvidia-driver` went from `-3` to `-5` and only `-4` and `-5` remain; the COPR's
  fedora-45 repodata kept 8 kernel builds, not 5.
- Verify the tag of `kernel.env` with `git verify-tag` against `tag_key` alone, and
  compare its uncompressed `git archive` with Source0; both held for 7.3.0-4.
- Expect the tag number at the front of the release (`7.3.0-4.cachyos1`); the `.apexN`
  suffix goes after it.
- The NVIDIA modules carry BTF. negativo17's spec does not BuildRequire dwarves, so
  `kmod-build.sh` installs it; and kbuild makes a module's BTF against the kernel's
  `vmlinux`, which `kernel-cachyos-devel` does not ship ("Skipping BTF generation for
  nvidia.ko due to unavailability of vmlinux", with dwarves alone), so `pair.sh` passes
  `OUT/debug/vmlinux` as `VMLINUX` and `kmod-build.sh` puts it into the kernel tree.
  `check.sh` holds the pair when an NVIDIA module has no `.BTF` section. On 2026-10-30,
  615.78.08 on the COPR's 7.3.0-4 `-devel`, with that kernel's `vmlinux` unpacked from
  its `vmlinuz`, gave all five modules a `.BTF` section, still signed.
- Apply `kernel-spec.patch`, which carries all of ADR 0015 §1's hunks: `pair.sh` passes
  `APEX_RELEASE` (the lane's N) as `apex_release` and `series` as `apex_series`. Core
  `%post` stays as shipped, so its `rpm-state` marker is no longer removed; it is
  harmless. `CC="ccache gcc"` is left out: ccache works from `PATH` without a spec
  change. The hunks are checked on the spec text by the selftest and parsed by
  `rpmspec` in `fedora:45`; a whole build with them is a builder-VM proof still owed.
- Keep the module key at `/run/apex-modkey/signing_key.pem` in every job, so ccache hits
  directly (33 min against 15 min for the kernel).
- Expect release-only bumps: `7.2.8-cachyos2` differs from `-cachyos1` only in its
  `Release:` line; the config, the BORE patch and Source0 are byte-identical. The bump
  report can say so, and the content key still changes.
- Keep `vmlinux` before rpmbuild drops it: rpm 6.1 runs `rmbuild` after `-bb` and
  `--rebuild`, so the build tree is gone when the job ends. `pair.sh` passes
  `--noclean` and copies it to `OUT/debug/`.
- Install `perl-Math-BigInt`, `file`, `diffutils`, `binutils`, `kmod` and `cpio` before
  `check.sh`.
- The two gates of ARCHITECTURE 4.2 beyond `check.sh`: BTF present is `pair.sh`'s (a
  `.BTF` section in `OUT/debug/vmlinux`, else a `kernel:` hold); the module count within
  5 % of the previous pair is apex-lane's, which alone sees the last good pair.
- Sign the kernel and kmod RPMs with the Apex RPM key, and take them through `[apex]`
  with `gpgcheck=1`; the spike used an unsigned local repository.
- In `qualify.sh`, key G4 on `kernel-cachyos-core` (and the kmod) instead of `kernel`,
  and assert the SELinux mode, which K1 read outside G4.
- In the Containerfile: the Fedora kernel names in the `excludepkgs` line, `--install`
  of the kernel, the kmod and the NVIDIA set, `--no-initramfs`, `depmod -a` before
  dracut, and the kargs above. negativo17's `99-nvidia.conf` already omits the NVIDIA
  modules from the initramfs.

## Risks

| Risk | What K1 saw | Response |
|---|---|---|
| NVIDIA 615 does not build on 7.3 | 615.78.08-1 builds on 7.3.0-4.cachyos1 unmodified, with the same warnings as on 7.2.11 (step 5) | the kmod build in every bump report; a new major waits for the owner |
| NVIDIA's RM core has returns objtool cannot patch | 11,669 "'naked' return found in MITIGATION_RETHUNK build" lines in `nvidia.o`, on 7.2.11 and 7.3.0 alike | upstream's; part of the K3 review of the AMD return-thunk mitigations |
| The config arrives from an unpinned URL | between `cachyos1` and `cachyos2` nothing but the release changed | the bump report's config diff, as planned |
| No second source for the negativo17 fingerprint | the COPR key is in Fedora's signed `distribution-gpg-keys-copr` since 2023, the tag key on two keyservers (step 5); negativo17's is on no keyserver and in no signed git history | nothing reads `nvidia.env` yet; the owner decides before S1c's lane trusts its key |
| The NVIDIA userspace was never composed | mirrored and signature-checked; the test image held only the kmod side | S1c composes it under the legacy gate |
| The host runs short while the desktop VM runs | 982,572 kB available and 4.5 GiB of swap in use during the cold build | kernel jobs at night on AC, as planned; no bigger VM |
| The GPU itself is untested | the guest has no NVIDIA device | ACCEPTANCE §4 on the laptop (K3) |
| Secure Boot | not exercised; the kernel trusts only its own certificate | W3 |
