# kernel-cachyos and NVIDIA's open modules, built as one pair

The CachyOS kernel (GCC build) rebuilt from the COPR's signed SRPM, and negativo17's
`nvidia-kmod` built for exactly that kernel in the same job, both signed with one key
that lives only for that job ([ADR 0015](../../../docs/adr/0015-cachyos-kernel-and-nvidia.md),
[ARCHITECTURE 4.2](../../../docs/ARCHITECTURE.md#42-kernel-and-nvidia-lane-s1c)). The lane
that runs the pair job arrives in roadmap S1c. Until then this directory holds what the
K1 spike proved and the pieces S1c reuses. There is no `pkg.env`, so neither `apex-lane`
nor `image.sh` sees a kernel family yet.

| File | Role |
|---|---|
| `kernel-spec.patch` | the one spec change the pair needs: `CONFIG_MODULE_SIG_KEY` names the job's key (`--define 'apex_module_sig_key PATH'`); the build stops without the define |
| `module-key.sh` | `generate DIR CN`: an ECDSA P-384 key and its certificate on a tmpfs, the kernel's own certificate extensions; `shred DIR`: the private key goes, the DER certificate stays |
| `kmod-build.sh` | in the container that built the kernel: installs its `kernel-cachyos-devel`, checks the GCC major, rebuilds the `nvidia-kmod` SRPM unmodified with `--define 'kernels <uname -r>'` and kmodtool's signing macros |
| `check.sh` | the lane checks of a pair (the lane's `check.sh` contract, plus `MODULE_CERT`): `config-required.txt`, the certificate built into `vmlinuz`, the signer of every module, the NVIDIA signatures verified with `openssl cms`, `kernel-uname-r`, no private key in a payload |
| `config-required.txt` | the config lines ADR 0015 relies on, compared verbatim |
| `patches/` | the ALC294 quirk, out of any series (ADR 0015, section 8) |

## K1, 2026-10-02

Steps 1 to 4 of the roadmap's K1 ran in the builder VM (8 vCPUs, 6 GiB, Fedora 45,
`podman` as root, containers of `image/Containerfile`'s `REPOS_BASE`
`fedora@sha256:1e13e11f…`, repositories `fedora` and `updates` only). Step 5, the same
builds on Linux 7.3.0, waits for the COPR. Every number below comes from a saved
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
- Apply `kernel-spec.patch`. The compose needs no spec change; the ADR's other hunks
  (the `.apexN` release, `_disable_source_fetch 1`, the series, `%posttrans` reduced to
  `depmod`, `CC="ccache gcc"`) were not tested here. ccache works from `PATH` without one.
- Keep the module key at `/run/apex-modkey/signing_key.pem` in every job, so ccache hits
  directly (33 min against 15 min for the kernel).
- Expect release-only bumps: `7.2.8-cachyos2` differs from `-cachyos1` only in its
  `Release:` line; the config, the BORE patch and Source0 are byte-identical. The bump
  report can say so, and the content key still changes.
- Keep `vmlinux` before rpmbuild drops it: rpm 6.1 runs `rmbuild` after `-bb` and
  `--rebuild`, so the build tree is gone when the job ends.
- Install `perl-Math-BigInt`, `file`, `diffutils`, `binutils`, `kmod` and `cpio` before
  `check.sh`.
- Add the two gates of ARCHITECTURE 4.2 that `check.sh` does not run yet: BTF present,
  and the module count within 5 % of the previous pair.
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
| NVIDIA 615 does not build on 7.3 | builds on 7.2.8 with negativo17's two Anatase patches | K1 step 5 when the COPR ships 7.3.0 |
| The config arrives from an unpinned URL | between `cachyos1` and `cachyos2` nothing but the release changed | the bump report's config diff, as planned |
| No second source for the two key fingerprints | not on the two keyservers tried; two third-party repositories (secureblue, margine-image) pin the same fingerprints, read from the same URLs before 2026-09-03: consistent over time, not an independent channel | check another source before the pins land |
| The NVIDIA userspace was never composed | mirrored and signature-checked; the test image held only the kmod side | S1c composes it under the legacy gate |
| The host runs short while the desktop VM runs | 982,572 kB available and 4.5 GiB of swap in use during the cold build | kernel jobs at night on AC, as planned; no bigger VM |
| The GPU itself is untested | the guest has no NVIDIA device | ACCEPTANCE §4 on the laptop (K3) |
| Secure Boot | not exercised; the kernel trusts only its own certificate | W3 |
