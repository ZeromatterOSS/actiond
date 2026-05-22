# Linux Reflink Materialization

## Goal

Add a Linux execution input mode that uses filesystem reflinks to materialize
action execroots from CAS blobs with native kernel file I/O and no custom host
kernel filesystem.

This is not expected to replace the VM/actiondfs fast path without benchmarks.
It is a Linux-native alternative worth measuring because our Linux machines are
primarily btrfs, where reflinks are cheap and ordinary file reads, mmap, splice,
and page-cache behavior stay in the host kernel.

The target mode should work with privileged Linux execution first and should be
compatible with rootless execution when user namespaces and the backing
filesystem allow the needed operations.

## Motivation

The current fastest path uses actiondfs inside the VM:

- input tree metadata is lazy
- repeated Directory protos are cached by digest
- file contents are served by opening real CAS backing files
- `read_iter`, `splice_read`, and `mmap` delegate to the backing filesystem

The direct Linux path instead prepares an execroot with read-only bind mounts
from CAS and materialized tree directories. That avoids a custom host kernel,
but it pays mount/setup costs and has rootless/container constraints.

Reflink materialization explores a middle ground:

- keep native Linux file I/O after setup
- avoid per-file data copies when the backing filesystem supports COW clones
- give each input path its own inode so executable bits and per-action metadata
  can be represented without mutating immutable CAS blobs
- avoid requiring actiondfs, FUSE passthrough, loop devices, or a VM

The tradeoff is that reflink materialization is eager. It must create directory
entries for the action input tree before execution, so it will not match
actiondfs on workloads with huge declared inputs that are rarely opened. The
question is whether btrfs reflinks are cheap enough for common Linux workloads.

## Target Shape

Add an explicit Linux input materialization mode:

```text
linux-actiond serve --input-mode=reflink
```

or an environment-gated experimental flag if the CLI should stay smaller during
benchmarking:

```text
ACTIOND_LINUX_INPUT_MODE=reflink linux-actiond serve ...
```

Execution remains otherwise unchanged:

1. Resolve the REAPI input root.
2. Create the per-action execroot under the worker root.
3. Walk the input tree.
4. For each directory, create the directory in the execroot.
5. For each file, clone the CAS blob into the execroot with reflink.
6. Apply executable mode bits to the execroot copy.
7. Bind runtime directories as today.
8. Run the action in the existing chroot/mount/network namespace flow.
9. Collect declared outputs from the execroot as today.

CAS blobs remain immutable. The reflinked execroot file is the mutable per-action
copy. If an action rewrites an input, btrfs performs COW for the modified extents
without changing CAS.

## Filesystem Requirements

Initial support should be btrfs-first:

- worker root and CAS blob root must be on the same btrfs filesystem
- CAS blob files should be ordinary files, not mounted from another filesystem
- reflink should use `FICLONE` or `copy_file_range` only when it is confirmed to
  create a clone, not a data copy
- cross-device CAS or runtime layouts should fall back clearly or reject the mode

Probe at server startup and again defensively on the first action:

1. Create a small source file under the CAS/root filesystem.
2. Clone it into a temp file under the work root using `ioctl(FICLONE)`.
3. Verify success.
4. Optionally verify shared extents with FIEMAP or `statx`/filesystem-specific
   checks if a cheap reliable probe is available.

Avoid silently falling back to full copies in the `reflink` mode. A silent copy
fallback would make benchmark results misleading and could make large actions
unexpectedly expensive.

## Rootless Compatibility

Reflinking ordinary files does not require `CAP_SYS_ADMIN`, so this can be a good
fit for rootless Linux if the worker root and CAS are writable by the actiond
user.

Rootless execution still has the existing namespace requirements:

- unprivileged user namespaces must be allowed
- the child must be able to create mount and network namespaces
- bind mounts for runtimes and any remaining input mounts must work
- `chroot` must happen inside a namespace where the child has the needed
  namespaced capabilities

For rootless mode, prefer:

```text
linux-actiond serve --rootless --runtime-root=/path/to/extracted-runtimes --input-mode=reflink
```

Do not combine rootless mode with loop-mounted SquashFS runtimes.

## Materializer Design

Extend the existing materializer rather than adding a second execroot builder
from scratch.

Suggested shape:

```zig
pub const InputMaterializationMode = enum {
    bind_mounts,
    reflinks,
};
```

`execroot.Materializer.materializeInputs` can dispatch to:

- current bind-mount behavior
- reflink behavior

For reflink behavior:

- create parent directories eagerly
- clone file inputs from `cas_blob_root_path/<shard>/<hash>` to the execroot path
- apply `0444` or `0555` based on REAPI executable metadata
- materialize directory inputs recursively
- preserve the existing path validation rules
- keep declared output parent creation unchanged

Tree artifacts can be handled the same way as source directories: walk the CAS
Directory metadata and reflink all file children into the execroot.

## Caching Options

Start with per-action reflink materialization only. It is simple and gives a
clean comparison against current direct Linux bind mounts.

If benchmarks show directory walking dominates, add cached materialized trees:

```text
<root>/materialized-trees/<hash>/
```

For a cached tree:

1. Build the tree once from CAS using reflinks.
2. Mark it read-only.
3. For each action, clone the cached tree into the execroot.

Whole-tree clone support is filesystem/tooling dependent, so the first cached
version may still walk the directory tree and reflink files from the cached tree.
That can still reduce protobuf parsing and CAS path resolution.

Do not add cached trees before measuring the simpler path.

## Benchmark Plan

Use the existing e2e stress workspace for functional and synthetic coverage:

```bash
ACTIOND_LINUX_INPUT_MODE=reflink tools/e2e.sh linux
```

Keep timings for:

- input fetch/materialize time
- child setup time
- process/io time
- output upload/collect time
- number of files reflinked
- number of directories created
- number of Directory protos parsed
- reflink failures
- fallback/copy attempts, which should be zero in strict reflink mode

For realistic performance, add a Linux-host LLVM smoke comparable to the VM
smoke:

```bash
ACTIOND_LINUX_INPUT_MODE=reflink e2e/llvm_tblgen_smoke.sh
```

Compare at least:

- direct Linux bind-mount mode
- direct Linux reflink mode on btrfs
- VM/actiondfs mode when available

Useful derived metrics:

- total Bazel elapsed
- action execution count
- mean/p50/p95 input materialization
- total number of reflinked files
- total bytes logically cloned
- physical disk growth during the run
- warm-cache second run behavior

Because reflinks are eager, benchmark both workloads with many unused declared
inputs and workloads that read most inputs.

## Expected Outcomes

Likely wins:

- fewer mount operations than per-file bind mounting
- rootless-friendlier than loop devices or host actiondfs
- native mmap/read behavior on action input files
- input mutation compatibility through btrfs COW semantics

Likely losses versus actiondfs:

- eager directory and inode creation before execution
- repeated per-action path creation unless cached trees are added
- more disk metadata churn
- no VM-lifetime lazy Directory cache unless implemented in userspace

The implementation should be considered successful if it materially improves
direct Linux execution on btrfs and gives a credible rootless path, even if it
does not beat VM/actiondfs.

## Open Questions

- Is `FICLONE` enough across all btrfs layouts used by our workers?
- Should reflink mode require CAS and work roots to share one filesystem?
- Should chmod happen after cloning, or should executable/non-executable CAS
  blobs get separate cached materialized files?
- How often do actions mutate input files in practice?
- Does eager reflinking reduce or increase total page-cache effectiveness versus
  bind mounts from CAS?
- Is cached tree materialization worth the invalidation and cleanup complexity?
- Can this mode be made reliable inside Distrobox, or should Distrobox support
  remain best-effort with an explicit probe?

## Non-Goals

- Do not replace VM/actiondfs before benchmark evidence exists.
- Do not silently fall back to full file copies in strict reflink mode.
- Do not require root, loop devices, or custom host kernel modules for this mode.
- Do not change the default Linux execution mode until the performance and
  compatibility tradeoffs are measured.
