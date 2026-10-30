# Packaging

The packages Apex rebuilds for this machine's hardware. Nothing here runs on its own:
apex-image's builder VM pipeline pins this repository by commit, runs the builds in
Fedora 45 containers, signs the RPMs with the Apex RPM key and feeds them to the image
compose ([apex-image packaging](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md)).

| Piece | Builds | Built by | Output |
|---|---|---|---|
| `libfprint/` | Fedora's libfprint SRPM plus the ELAN 04f3:0c6e patches | apex-image's builder VM (`.github/scripts/libfprint.sh build`) | `_build/libfprint/`, or "degraded" |
| `pkgs/kernel/` | the CachyOS kernel and NVIDIA open modules as one pair ([ADR 0015](https://github.com/apex-linux/apex/blob/main/docs/adr/0015-cachyos-kernel-and-nvidia.md)) | apex-image's `apex-lane` pair kind (`source=copr-srpm`), once a `pkg.env` here asks for it | none yet: no `pkg.env` |

## libfprint

See [libfprint/README.md](libfprint/README.md). In short: `build.sh key` gives the cache
key (Fedora's libfprint NVR plus a hash of the enabled patches); `build.sh` downloads
the same SRPM the compose would install, verifies its signature against the
pinned Fedora 45 key, applies `series`, builds `libfprint-…-1.fc45.apex1`, and runs the
elan replay tests. apex-image's `build-image.sh` then signs its RPMs with the Apex RPM key, and its
`manifest.txt` records it ([Signing](https://github.com/apex-linux/apex-image/blob/main/packaging/README.md#signing)). Exit 3 means degraded: the image ships
Fedora's stock libfprint with `io.github.apex-linux.apex.degraded=fingerprint`, so OS
updates never wait for this package.

## Kernel and NVIDIA (S1c)

The image will boot the CachyOS kernel (GCC build), rebuilt from the COPR's signed SRPM,
with NVIDIA's open modules built for exactly that kernel in the same job
([ADR 0015](https://github.com/apex-linux/apex/blob/main/docs/adr/0015-cachyos-kernel-and-nvidia.md)). apex-image's `apex-lane`
already has the pair kind (`source=copr-srpm`) that runs the job. `pkgs/kernel/` holds
what the K1 spike measured and what the job runs: the spec patch, the per-build module
key, the pair job, the kmod build, the pair's checks and the pins
([pkgs/kernel/README.md](pkgs/kernel/README.md)); it has no `pkg.env`, so no image takes
the kernel yet: that waits on the owner's decision on negativo17's key. `pkgs/kernel/patches/` holds only the ALC294 quirk, which is out of any
series: it ships only if the `model=` alias fails (ADR 0004, as amended).
