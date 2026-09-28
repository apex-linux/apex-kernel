# apex-spec-header.inc: prepended to Fedora's kernel.spec by copr.mk (README.md here).
# Everything below uses hooks the Fedora spec already reads; no line of it is edited.
# (This file becomes part of a spec: a percent sign in a comment must be doubled.)

# Release: kernel.spec sets specrelease to 300%%{?buildid}%%{?dist}, so the package is
# kernel-7.2.7-300.1.apex.fc45. It sorts above Fedora's kernel-7.2.7-300.fc45 and below
# Fedora's next build (7.2.7-301.fc45 or 7.2.8-300.fc45), which is what the ADR 0005
# fallback to the stock kernel relies on. Bump .1 to .2 only to rebuild the same
# Fedora release.
%define buildid .1.apex

# Zen 3 (Ryzen 5 5600H). BuildKernel passes this as KCFLAGS. CONFIG_X86_NATIVE_CPU is
# not used, because it would tune for whatever CPU the COPR builder has.
%global kcflags -march=znver3 -mtune=znver3

# Variants Apex never boots: the debug kernel, the selftests and the kernel-uki-virt
# unified kernel image (the laptop boots kernel plus initramfs through GRUB).
%define _without_debug 1
%define _without_selftests 1
%define _without_efiuki 1

# debuginfo stays ON, deliberately:
# - With _without_debuginfo the spec rewrites every CONFIG_DEBUG_INFO*=y in the config to
#   "is not set" (kernel.spec, "if with_debuginfo == 0"). That removes DEBUG_INFO_BTF and
#   with it SCHED_CLASS_EXT and /sys/kernel/btf/vmlinux, which sched_ext schedulers, the
#   BPF CO-RE tools and systemd's BPF LSM features need. kernel-local pins both to y, so
#   the build would stop at the config check anyway.
# - kernel-debuginfo is the only way to read a crash or a drgn session of a kernel that
#   Fedora's debuginfod has never seen.
# The price is build time and COPR storage; the image installs no debuginfo package.
# Optional, when Fedora's own perf and tools are good enough: _without_perf, _without_tools.
