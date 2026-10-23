# apex-kernel

The kernel and libfprint rebuilds of [Apex](https://github.com/apex-linux/apex) for the
ASUS Vivobook Pro 14X OLED (M7400QC).

- **libfprint** (`packaging/libfprint/`): Fedora's libfprint with the ELAN `04f3:0c6e`
  patches, rebuilt from Fedora's signed SRPM. A build that cannot ship leaves the image
  on Fedora's stock libfprint, labelled `degraded=fingerprint`
  ([ADR 0006](https://github.com/apex-linux/apex/blob/main/docs/adr/0006-fingerprint-libfprint-rebuild.md)).
- **Kernel** (`packaging/pkgs/kernel/`): the CachyOS kernel and NVIDIA's open modules,
  built as one pair and signed with a per-build key
  ([ADR 0015](https://github.com/apex-linux/apex/blob/main/docs/adr/0015-cachyos-kernel-and-nvidia.md)).
  The K1 spike's results are here; the lane that ships the pair arrives in roadmap S1c.

[packaging/README.md](packaging/README.md) has the details.
[apex-image](https://github.com/apex-linux/apex-image) pins this repository by commit
and runs the builds in its builder VM pipeline.

## Development

```bash
just check          # shellcheck and the script self-tests, as CI runs them
just libfprint-key  # the libfprint cache key
just libfprint      # print the root command that rebuilds libfprint in a fedora:45 container
```

## License

The scripts are GPL-3.0-or-later (`LICENSE`). The kernel patches are GPL-2.0
(`LICENSE.GPL-2.0`) and the libfprint patches LGPL-2.1-or-later (`LICENSE.LGPL-2.1`),
the licences of the projects they modify.
