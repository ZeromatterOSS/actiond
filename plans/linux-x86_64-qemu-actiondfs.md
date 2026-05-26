# Linux x86_64 QEMU actiondfs VM Plan

## Goal

Bring the high-performance actiondfs execution path to Linux x86_64 hosts by
running the same guest-owned CAS/actiondfs VM model that `darwin-actiond
serve-vm` uses on macOS, but with `qemu-system-x86_64` and KVM instead of
Virtualization.framework.

The Linux direct `linux-actiond serve` path should remain available and should
continue to work on ordinary host kernels. The new path is a Linux VM host path
for cases where we want the custom actiondfs kernel and the same lazy input
filesystem behavior used by the macOS VM path.

## Research Check

The proposed shape matches the high-performance path for Linux:

- QEMU documents direct Linux boot with `-kernel`, `-initrd`, and `-append`,
  which matches actiond's existing packaged custom kernel/initramfs model.
  Source: https://qemu-project.gitlab.io/qemu/system/linuxboot.html
- QEMU recommends virtio devices as the efficient/default paravirtualized device
  family, and notes vhost can move device implementation into the host kernel.
  Source: https://www.qemu.org/docs/master/system/devices/virtio/index.html
- The virtio-vsock spec defines host/guest socket transport without Ethernet/IP
  and reserves CID 2 as the well-known host CID. This matches the current
  actiond bridge model and avoids adding guest networking.
  Source: https://docs.oasis-open.org/virtio/virtio/v1.2/csd01/virtio-v1.2-csd01.pdf
- QEMU's virtio storage guidance recommends virtio storage over emulated
  controllers and recommends virtio-blk for performance-critical disk use. That
  matches the current VM shape: one writable CAS ext4 disk and one read-only
  runtime SquashFS disk.
  Source: https://www.qemu.org/2021/01/19/virtio-blk-scsi-configuration/
- QEMU block invocation docs expose `cache=...`, `aio=native`, and
  `aio=io_uring`. We should start conservative with raw virtio-blk images and
  make `aio=io_uring`/iothreads a later measured tuning, because the canonical
  actiondfs bottleneck is expected to be guest filesystem and CAS page-cache
  behavior, not the host block queue.
  Source: https://qemu-project.gitlab.io/qemu/system/invocation.html

Conclusion: using QEMU/KVM, direct custom kernel boot, virtio-vsock, and
virtio-blk is the right Linux equivalent of the current macOS high-performance
path. TCG emulation is not an acceptable default for this mode; if `/dev/kvm`
is unavailable or unusable, fail with a clear error unless an explicit debug
flag opts into slow emulation.

## Target Architecture

The new Linux VM mode should preserve this request/data flow:

```text
Bazel
  |
  | gRPC / REAPI
  v
Linux host actiond VM frontend
  |
  | raw gRPC bytes over AF_VSOCK
  v
linux-actiond-guest in QEMU/KVM VM
  |
  | guest CAS / ByteStream / AC / Capabilities / GetTree / Execute
  v
guest ext4 CAS on virtio-blk, action inputs through actiondfs
```

The host frontend should still:

- extract or accept kernel/initramfs/runtime artifacts
- create or accept the CAS ext4 image
- start one long-lived guest
- listen on the public TCP endpoint
- proxy gRPC streams to guest vsock port 5001
- query guest control vsock port 5000 for `/proc/actiondfs_stats`

The guest should still:

- mount proc/sysfs/cgroup/devtmpfs/tmpfs
- mount writable CAS ext4 at `/cas`
- mount read-only runtime SquashFS at `/runtimes`
- run `linux-actiond-guest --guest-worker`
- execute actions with `use_actiondfs = true`

## Build Changes

1. Add x86_64 guest binary packaging:
   - add `//cmd/linux_actiond_guest:linux-actiond-guest-x86_64-raw`
   - add `//cmd/linux_actiond_guest:linux-actiond-guest-x86_64`
   - build it with `target_platform = "//platforms:linux_x86_64"`

2. Split VM initramfs outputs by architecture:
   - keep existing aarch64 initramfs for macOS VM
   - add x86_64 initramfs containing `linux-actiond-guest-x86_64`
   - expose an alias such as `//vm:initramfs` that selects by target platform
     only if that remains unambiguous; otherwise use explicit
     `//vm:initramfs_aarch64` and `//vm:initramfs_x86_64`

3. Add x86_64 custom kernel build:
   - extend `linux_kernel.compact`/`compact_repos` for x86_64
   - add an x86_64 VM kernel target, likely using x86 `bzImage` as the direct
     QEMU boot artifact rather than arm64 `Image`
   - keep `CONFIG_ACTIONDFS_FS=y`
   - keep virtio block, virtio PCI, virtio vsock, ext4, squashfs, overlayfs,
     cgroups, namespaces, seccomp, tmpfs, proc/sysfs, and devtmpfs
   - add/verify x86 serial console config needed for `-nographic` and
     `console=ttyS0`

4. Add x86_64 VM bundle aliases:
   - `//vm:linux_kernel_x86_64`
   - `//vm:linux_kernel_x86_64_zst`
   - `//vm:initramfs_x86_64`
   - `//vm:vm_bundle_x86_64`

5. Extend standalone payload embedding for Linux VM mode:
   - add ELF sections for `.actiond.kernel`, `.actiond.initramfs`, and
     `.actiond.runtimes`, or introduce a generic payload table section
   - teach `embedded_payload.zig` to find kernel/initramfs in ELF, not just
     Mach-O
   - keep the existing `.actiond.runtimes` section compatible for direct
     `linux-actiond-standalone serve`

## Host Code Changes

1. Rename or generalize the macOS-only host layer:
   - move the platform-independent code in `src/darwin_vm_host.zig` to a name
     like `src/vm_host.zig`
   - keep argument parsing, payload extraction, boot artifact inflation, CAS
     image creation, stats polling, and TCP-to-vsock bridge setup shared
   - keep a compatibility import from `darwin_vm_host.zig` if useful for
     low-risk migration

2. Define a small machine interface used by the bridge/control client:
   - `start(options) -> Machine`
   - `deinit()`
   - `connectControlPort(port) -> fd`
   - `opener() -> control_transport_fd.Opener`

3. Keep the existing macOS implementation as the Virtualization.framework
   backend.

4. Add `src/qemu_vm.zig` for Linux:
   - locate `qemu-system-x86_64` from `PATH` or a `--qemu=/path` option
   - verify Linux host and x86_64 architecture
   - verify `/dev/kvm` before starting unless `--allow-tcg` is explicitly set
   - allocate a unique guest CID for each VM, defaulting to a stable private
     range and checking for connect collisions where practical
   - spawn QEMU as a child process and keep its PID/handle
   - connect to the guest with host AF_VSOCK sockets using guest CID + port
   - terminate and reap QEMU in `deinit`

5. QEMU command line draft:

```text
qemu-system-x86_64
  -machine q35,accel=kvm
  -cpu host
  -smp <cpus>
  -m <memory_mib>M
  -nodefaults
  -nographic
  -no-reboot
  -serial mon:stdio
  -kernel <bzImage>
  -initrd <initramfs.cpio>
  -append "console=ttyS0 panic=-1"
  -device vhost-vsock-pci,id=vsock0,guest-cid=<cid>
  -drive if=none,id=cas,file=<cas.ext4>,format=raw,cache=none,aio=io_uring
  -device virtio-blk-pci,drive=cas
  -drive if=none,id=runtimes,file=<runtimes.sqfs>,format=raw,readonly=on,cache=none
  -device virtio-blk-pci,drive=runtimes
```

Initial implementation may use `aio=threads` or omit `aio` if `io_uring` is not
available on common worker hosts. Make this configurable and measure before
making `io_uring` a hard dependency.

6. Add `serve-vm` to the Linux VM standalone entrypoint:
   - preferred minimal user surface: `linux-actiond-vm-standalone serve-vm ...`
   - keep `linux-actiond-standalone serve ...` as the direct host path
   - if we want to preserve the current macOS naming in scripts, add a
     cross-platform `actiond-vm-host-standalone` alias later rather than
     requiring Linux users to run a binary named `darwin-actiond`

## Guest and Kernel Considerations

- The current guest block-device probing already tries `/dev/vd*` and scans
  `/sys/block`, so QEMU virtio-blk should fit without guest changes.
- Device ordering matters because the guest mounts the first ext4 candidate as
  CAS and the first SquashFS candidate as runtimes. Attach CAS before runtimes
  and add tests or a label-based fallback if ordering proves brittle.
- Keep networking disabled. The guest should communicate only through vsock,
  and actions should still get only loopback in their private network namespace.
- Keep the guest-owned CAS model. Do not introduce a host CAS mirror or
  virtiofs shared CAS in the first implementation; that would change the
  actiondfs performance profile and failure model.
- Do not try to use host-kernel actiondfs on Linux as the default path. It would
  require installing a custom kernel/module on workers and would not match the
  hermetic VM model used by macOS.

## Implementation Status

Implemented on branch `user/wgray/linux-actiondfs`:

- shared VM host code in `src/vm_host.zig`
- Linux QEMU/KVM backend in `src/qemu_vm.zig`
- Linux `serve-vm` CLI in `cmd/linux_actiond`
- ELF embedded payload lookup for standalone Linux VM artifacts
- x86_64 guest binary, initramfs, custom kernel config, and VM bundle targets
- Linux `tools/e2e.sh linux-vm` harness mode
- Linux-aware `e2e/run_llvm_vm_smoke.sh` wrapper for the canonical actiondfs
  LLVM smoke

Darwin code remains a thin compatibility wrapper over the shared VM host path;
the Darwin-specific backend remains Virtualization.framework.

Validation completed:

- `bazel build //...` passed
- `tools/e2e.sh linux-vm` passed with the standalone Linux VM bundle and QEMU/KVM
- `e2e/run_llvm_vm_smoke.sh` passed on Linux x86_64 with QEMU/KVM and recorded
  actiondfs counters in `e2e/LLVM_VM_SMOKE_TIMINGS.md`

Known follow-up:

- `bazel test //...` currently fails in the zstd-backed tool tests
  `//tools:sqfs_pack_tests`, `//tools:initramfs_newc_tests`, and
  `//tools:zstd_file_tests`. The failing tests segfault in existing zstd
  compression round-trip coverage and are not specific to the QEMU VM path.
- The x86_64 linux.bzl `bzImage` currently boots under Bazel fastbuild but not
  under `-c opt`; the LLVM smoke keeps the measured LLVM workload opt-built and
  builds the Linux VM bundle in fastbuild by default.

## Test Plan

Phase 1, build/unit:

```bash
bazel build //cmd/linux_actiond_guest:linux-actiond-guest-x86_64
bazel build //vm:linux_kernel_x86_64_zst
bazel build //vm:initramfs_x86_64
bazel build //cmd/linux_actiond:linux-actiond-vm-standalone_pkg
bazel test //src:unit_tests
```

Phase 2, boot smoke:

```bash
tools/create_ext4_image.sh /tmp/actiond-qemu-cas.ext4 8192
linux-actiond-vm-standalone serve-vm \
  --listen=127.0.0.1:8998 \
  --root=/tmp/actiond-qemu-vm \
  --cas-image=/tmp/actiond-qemu-cas.ext4 \
  --memory-mib=4096 \
  --cpus=8 \
  --actiondfs-stats-path=/tmp/actiondfs_stats.txt
```

Confirm:

- TCP listener accepts connections
- `/tmp/actiondfs_stats.txt` appears and updates
- guest log shows `/cas` ext4 and `/runtimes` SquashFS mounted
- `actiondfs_mounts` appears in execute timing lines for VM actions

Phase 3, e2e harness:

```bash
tools/e2e.sh linux-vm
ACTIOND_E2E_STANDALONE=1 tools/e2e.sh linux-vm
```

Add `linux-vm` rather than overloading the current `linux` mode, because
`linux` means direct host execution today.

Phase 4, realistic performance smoke:

```bash
ACTIOND_LLVM_VM_SMOKE_PORT=8998 \
ACTIOND_VM_CAS_IMAGE_SIZE_MIB=8192 \
ACTIOND_VM_MEMORY_MIB=4096 \
ACTIOND_VM_CPUS=4 \
ACTIOND_LLVM_SMOKE_JOBS=4 \
e2e/run_llvm_vm_smoke.sh
```

The script starts `linux-actiond serve-vm` with QEMU/KVM on Linux x86_64 and
updates the canonical actiondfs timing summary in
`e2e/LLVM_VM_SMOKE_TIMINGS.md`. Compare against direct Linux execution and,
when available, the macOS VM baseline.

Final repository checks for implementation PRs:

```bash
bazel build //...
bazel test //...
tools/e2e.sh linux
tools/e2e.sh linux-vm
```

Do not claim the macOS VM path was tested unless `tools/e2e.sh vm` completed on
macOS.

## Rollout Strategy

1. Land the x86_64 guest/kernel/initramfs build graph first.
2. Land the platform-neutral VM host refactor with no behavior change on macOS.
3. Add the QEMU/KVM backend behind `serve-vm` on Linux.
4. Add Linux VM e2e coverage.
5. Add LLVM smoke support and timing docs.
6. Tune QEMU block options only after the LLVM smoke gives a stable baseline.

## Open Questions

- Should the Linux VM frontend live under `linux-actiond-vm-standalone serve-vm`,
  or should the project introduce a neutral `actiond-vm-host` binary and keep
  `darwin-actiond` as a compatibility wrapper?
- Should the first QEMU backend require `vhost-vsock-pci`, or allow
  `virtio-vsock-pci` fallback when `/dev/vhost-vsock` is unavailable? For
  performance mode, requiring vhost is cleaner; for developer machines, fallback
  may reduce setup friction.
- Should `io_uring` be default-on for the CAS disk, or should it remain an
  opt-in until measured on the target Linux workers?
- Should the guest identify CAS/runtime disks by filesystem type only, as today,
  or should we add explicit virtio serials/labels to make QEMU device ordering
  impossible to misinterpret?
