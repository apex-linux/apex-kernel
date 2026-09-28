# libfprint rebuild (ELAN 04f3:0c6e)

Fedora's libfprint rejects every pre-scan status of the ELAN `04f3:0c6e` reader other
than 0x55 as a protocol error. The upstream fix, MR !655, is not merged. Until it is,
Apex rebuilds **the libfprint SRPM that Fedora ships** with a short list of patches
([ADR 0006](../../docs/adr/0006-fingerprint-libfprint-rebuild.md),
[ARCHITECTURE 6.3](../../docs/ARCHITECTURE.md#63-fingerprint-elan-04f30c6e)).

| File | Role |
|---|---|
| `series` | the enabled patches, in the order they are applied |
| `patches/` | every patch Apex carries, enabled or not |
| `build.sh` | the rebuild, run by `.github/scripts/libfprint.sh build` in `registry.fedoraproject.org/fedora:45`, in the builder VM |

## What `build.sh` does

1. **Reads `series`** and refuses bad entries (see the format below) before it touches
   the network.
2. **Resolves the stock build** with `dnf repoquery` over exactly the repositories the
   image compose uses: `fedora` and `updates`, plus `updates-testing` restricted to
   `TESTING_INCLUDEPKGS` (the compose's updates-testing allowlist) while
   `GA_REACHED=0`. An empty allowlist means no `updates-testing` at all, as in the
   compose, never the whole of it (the pre-GA `fedora:45` image enables it by default,
   so the script always names its repositories). The rebuilt SRPM is therefore the
   version the compose would otherwise install, and fprintd and libfprint cannot drift
   apart.
3. **Downloads that SRPM** (`dnf download --srpm`, with the matching `-source`
   repositories). dnf checks it against the repository metadata only, so the script
   then:
   - compares the fingerprint of `/usr/share/pki/rpm-gpg/RPM-GPG-KEY-fedora-45-primary`
     with the one pinned in the script (`4F50 A611 4CD5 C697 6A7F 1179 655A 4B02 F577
     861E`, from fedoraproject.org/security and fedora-repos dist-git);
   - imports only that key with `rpmkeys --import`;
   - requires `rpmkeys -K` to report `signatures OK`, requires every signature line of
     `rpmkeys -Kv` to be `OK`, and requires one of them to name the Fedora key.

   Anything else stops the job with exit 1. `--nosignature` never appears here.
4. **Checks the release arithmetic.** Fedora's spec says `Release: %autorelease`; the
   SRPM that Koji builds carries the rpmautospec preamble that expands it to the real
   number followed by `%{?dist}`. The script proves this for every build instead of
   assuming it: with `dist=.fc45` the spec must yield the stock release, and with
   `dist=.fc45.apex1` it must yield the stock release plus `.apex1`. It then asks rpm
   itself (`rpm.vercmp`) that `1.94.100-1.fc45.apex1` sorts above `1.94.100-1.fc45`.
   A Fedora rebuild (`-2.fc45`) sorts above ours again. That is intended: the cache key
   changes, and the next full build in the builder VM rebuilds from the new SRPM.
   Until then the compose still takes ours, because the local repository has priority 1
   and the Fedora repositories carry `excludepkgs=libfprint`.
5. **Runs `%prep` twice.** First unpatched: if Fedora's own `%prep` fails, that is an
   infrastructure error (exit 1). Then with one `PatchNNNN:` line per series entry
   inserted after `Source0:` (numbered from 1001, in series order, copied to `SOURCES`
   as `apex-<name>`). Fedora's `%autosetup -S git` applies them with `git apply`, which
   allows no fuzz, so a patch whose context moved fails here instead of landing in the
   wrong place.
6. **Proves the tree is exactly Fedora's source plus the series:** it reverts the
   patches in reverse order on a copy of the prepared tree and compares the result with
   the unpatched tree (`diff -r`). This also catches a future spec that stops using
   `%autosetup`/`%autopatch` and would silently ignore the `Patch` lines.
7. **Builds** with `rpmbuild -bb --define 'dist .fc45.apex1'`.
8. **Tests** (see below), then copies the binary RPMs to `OUT_DIR` and writes
   `manifest.txt` and `key.txt`.

`build.sh key` stops after step 2 and prints the cache key. It was the tag of
`ghcr.io/sekirokenjii/apex-libfprint`; nothing publishes one now, so the builder VM
always builds. The key looks like this:

```
libfprint-1.94.100-1.fc45-s<first 12 hex digits of the series hash>
```

The series hash covers each enabled patch's name and content, `APEX_SUFFIX`,
`build.sh` itself and the repository options (which decide the build dependencies), so
any change that alters the output changes the key.

## Running it

In the builder VM, `.github/scripts/libfprint.sh build` runs it inside
`registry.fedoraproject.org/fedora:45`, as root, with the repository checked out. It
passes `GA_REACHED` and `TESTING_INCLUDEPKGS` with the image compose's values. The bare
command:

```bash
GA_REACHED=0 OUT_DIR=/out packaging/libfprint/build.sh
```

| Variable | Meaning |
|---|---|
| `OUT_DIR` | required: an empty or missing directory for the outputs |
| `GA_REACHED` | required: `0` before Fedora 45 GA (adds the allowlisted updates-testing builds), `1` after |
| `SERIES` | default `packaging/libfprint/series` |
| `TESTING_INCLUDEPKGS` | the compose's updates-testing allowlist, used only when `GA_REACHED=0`; empty means no updates-testing |
| `APEX_SUFFIX` | default `.apex1` |
| `RUN_TESTS` | `1` (default) or `0` |
| `KEEP_DEBUGINFO` | `1` also copies the `-debuginfo`/`-debugsource` RPMs |
| `FEDORA_KEY_FPR` | the release key fingerprint for a Fedora other than 45 |
| `FEDORA_KEY_DIR` | where the key file is, default `/usr/share/pki/rpm-gpg` (the fingerprint check still applies) |
| `WORK_DIR` | scratch directory, default a new `mktemp -d` |

By hand, run the same command in the Fedora 45 builder VM
([tools/builder-vm](../../tools/builder-vm/README.md)), for example
`podman run --rm -v "$PWD:/src:Z" -w /src registry.fedoraproject.org/fedora:45 env GA_REACHED=0 OUT_DIR=/src/target/libfprint packaging/libfprint/build.sh`.

## The `series` file

The format, with the entries enabled at the time of writing (the file itself is the
authority):

```
# Comments start with '#', also after a name. Blank lines are ignored.
0001-elan-Retry-transient-pre-scan-status-on-04f3-0c6e.patch
0002-elan-Bound-transient-retries-with-lift-semantics.patch
```

- One file name per line, relative to `patches/`, in application order.
- Names must look like `NNNN-short-name.patch`; paths, spaces and duplicates are
  rejected (exit 2).
- A series that enables nothing is an error too: at that point the rebuild has no
  purpose and the job should be retired (see the last section).

Patches are in `git format-patch` form: a `From:`/`Subject:` header, a message that says
where the change comes from (the upstream MR or issue), then a unified diff with `a/`
and `b/` prefixes, applied with `-p1`.

### Numbering: 00xx enabled, 01xx disabled

- **`00xx`**: a patch that may be listed in `series`. Numbers follow the application
  order.
- **`01xx`**: carried but disabled. The patch is kept in the tree, reviewed and kept
  applying on top of the enabled ones, but `build.sh` refuses to find it in `series`
  (exit 2). Per ADR 0006 the dark-frame recovery (`0101`) and the settle delay after
  stop (`0102`, a backport of MR !647) stay here until a diagnostic log from this laptop
  shows their trigger; `patches/README.md` describes each patch and the log lines to
  look for.
- **Enabling a 01xx patch:** attach the evidence (the log lines, not raw frames) to the
  change, `git mv` the file to the next free `00xx` number, add it to `series` and
  rebuild in the builder VM (`just vm-image`). Disabling works the other way round.

## Tests

Fedora's spec currently has no `%check` (its test run needs a pygobject fix), so there is
no `--nocheck` either: if Fedora restores `%check`, it runs here unchanged. The script
adds its own check because the patches change `elan.c`: libfprint ships umockdev
recordings, so the `elan` and `elan-cobo` driver tests replay a real capture through the
patched driver without any hardware. A control test of an untouched driver (`aes3500`,
`vfs5011` or `synaptics`) runs first:

| Control | elan tests | Result |
|---|---|---|
| fails | not run | `tests=inconclusive`: the harness is broken, not the patch; warning only |
| passes | fail | exit 3: the patched driver regressed |
| passes | pass | `tests=passed` |

These tests run with `FP_DEVICE_EMULATION=1`, which changes how the elan driver treats a
non-0x55 status, so they prove that a normal capture still works. They do not prove the
retry path itself: that is the hardware acceptance test in `docs/hardware/`.

## Outputs

- `OUT_DIR/*.rpm`: the binary RPMs (`libfprint`, `-devel`, `-tests`; debug RPMs only
  with `KEEP_DEBUGINFO=1`).
- `OUT_DIR/key.txt`: the cache key.
- `OUT_DIR/manifest.txt`, one line per artifact, `kind nevra sha256 file`; a patch
  line carries the patch name without `.patch` in the nevra column, one line per
  `series` entry in series order:

  ```
  # apex-libfprint manifest 1: kind nevra sha256 file
  # key=libfprint-1.94.100-1.fc45-s… fedora=45 ga_reached=0 dist=.fc45.apex1 tests=passed
  srpm libfprint-0:1.94.100-1.fc45.src <sha256> libfprint-1.94.100-1.fc45.src.rpm
  patch 0001-elan-Retry-transient-pre-scan-status-on-04f3-0c6e <sha256> 0001-elan-Retry-transient-pre-scan-status-on-04f3-0c6e.patch
  patch 0002-elan-Bound-transient-retries-with-lift-semantics <sha256> 0002-elan-Bound-transient-retries-with-lift-semantics.patch
  rpm libfprint-0:1.94.100-1.fc45.apex1.x86_64 <sha256> libfprint-1.94.100-1.fc45.apex1.x86_64.rpm
  ```

  The image build copies these lines into its provenance record.

## Exit codes and degrading

| Exit | Meaning | What the builder VM does |
|---|---|---|
| 0 | built | the image takes the RPMs in `_build/libfprint/` |
| 1 | error before any patch was tried: repository, download, signature, NVR arithmetic, unpatched `%prep` | the image build stops |
| 2 | usage or `series` error | the image build stops; fix the repository |
| 3 | **degraded**: a patch does not apply, the tree is not pristine plus series, the patched build fails, or the elan replay test fails | the image ships Fedora's stock libfprint; `OUT_DIR/degraded.txt` holds the reason |

Degrading never blocks OS updates (ADR 0006): the image build falls back to stock
libfprint (it drops `excludepkgs=libfprint` and the local libfprint package) and sets
the label `io.github.sekirokenjii.apex.degraded=fingerprint`, which `apexctl status`
shows. The reader then behaves as it does on stock Fedora (enrollment may fail with a
protocol error) until the series is fixed. Exit 1 stops the image build instead,
because it points at the pipeline, not at the patches.

## When upstream merges MR !655

No job watches the MR: GitHub runs only `ci.yml`. Check it and Fedora's builds by hand:

```bash
curl -s https://gitlab.freedesktop.org/api/v4/projects/libfprint%2Flibfprint/merge_requests/655 | jq -r '.state, .merged_at'
koji latest-build f45 libfprint
```

1. Once a libfprint release that contains !655 reaches Fedora 45, patch 0001 stops
   applying and the job degrades (exit 3). That is the expected signal.
2. Check upstream `libfprint/drivers/elan.h` and `elan.c`: 0x0c6e must be in the set
   that retries 0x00/0xaf instead of failing.
3. Remove 0001 from `series` and delete the file. Then look at every remaining patch:
   0002 bounds the retry that 0001 introduced; if upstream bounds it too, drop 0002;
   otherwise rebase it on upstream's names and keep it.
4. If `series` is now empty, retire the rebuild: remove the libfprint step from
   `tools/builder-vm/build-image.sh`, remove the local libfprint package and the
   `excludepkgs=libfprint` guard from the compose, and drop `fingerprint` from the
   degraded logic.
5. Before merging, run the fingerprint acceptance test on the laptop with the stock (or
   reduced) build.
