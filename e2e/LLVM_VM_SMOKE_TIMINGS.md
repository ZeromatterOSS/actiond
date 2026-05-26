# LLVM VM Smoke Timings

This file records the most recent checked-in LLVM VM smoke run. Re-run it with:

```bash
e2e/run_llvm_vm_smoke.sh
```

The script starts a fresh `darwin-actiond serve-vm` worker, runs `bazel clean
--expunge`, builds `@llvm-project//llvm:llvm-tblgen` from this repo's `@llvm`
module dependency, and writes parsed timing summaries under the printed output
directory. The VM build uses `@llvm//platforms:linux_arm64_musl` for both target
and host platform so generated exec tools run inside the Linux VM without glibc.
The runner also records a mac-host baseline with the same target platform and
the default macOS host platform. The latest output root is written to
`/tmp/actiond-last-llvm-vm-smoke-path`.

Both builds target `@llvm//platforms:linux_arm64_musl`. The VM build also uses
that as the host platform because exec tools run in Linux. The mac-host baseline
keeps the host platform as macOS so local exec tools are runnable on Darwin;
some output paths therefore still contain `darwin_arm64-opt` even though the
compile target triple is Linux musl.

`ACTIOND_LLVM_SMOKE_WARMUP_TARGET=<label>` can run a pre-measure build and parse
only the VM log slice after that warmup. The default is
`//e2e:llvm_exec_warmup`, a `cfg = "exec"` wrapper around
`@llvm-project//llvm:llvm-min-tblgen`. Aquery showed that
`@llvm//runtimes:resource_directory` is not the full VM/mac action-count delta:
the VM `llvm-tblgen` graph has 5,341 configured actions, the mac-host graph has
3,637, and `@llvm//runtimes:resource_directory` has 597. The exec warmup has
2,713 configured actions and the same 2,403 action keys as the Linux exec-config
subset of the VM `llvm-tblgen` graph.

## Latest Checked-In Result

- Generated: `2026-05-22 09:20:29 EDT`
- Command: `ACTIOND_LLVM_VM_SMOKE_ROOT=/tmp/actiond-llvm-cas-stage-stats-20260522-091717 ACTIOND_LLVM_SMOKE_MAC_HOST=0 ACTIOND_LLVM_SMOKE_VM=1 ACTIOND_LLVM_SMOKE_JOBS=8 e2e/run_llvm_vm_smoke.sh`
- Output root: `/tmp/actiond-llvm-cas-stage-stats-20260522-091717`
- Workload: `@llvm-project//llvm:llvm-tblgen`, jobs=8
- VM warmup target: `//e2e:llvm_exec_warmup`
- Target platform: `@llvm//platforms:linux_arm64_musl`
- VM host platform: `@llvm//platforms:linux_arm64_musl`
- Build mode: `-c opt --strip=always --stripopt=--strip-all`
- VM warmup elapsed: `55.146s`
- VM warmup processes: `2207 processes: 190 internal, 2017 remote`
- VM Bazel elapsed: `59.657s`
- VM executions: `2106`
- VM timing records parsed: `2106`
- VM Bazel processes: `2310 processes: 4 action cache hit, 204 internal, 2106 remote`
- Mac-host baseline: not run for this VM-focused actiondfs staging check

## Latest Linux QEMU/KVM Result

These runs use `linux-actiond serve-vm` with QEMU/KVM on Linux x86_64. The
workload is the same `@llvm-project//llvm:llvm-tblgen` smoke with a fresh VM
worker, 16 vCPUs, `--jobs=16`, optimized Zig code, native CPU codegen, and
`q35` unless otherwise noted.

The key tuning result on 2026-05-25 was the QEMU block backend. Keeping
`cache=none` but adding `aio=io_uring` moved the QEMU/KVM path from the
previous `121.914s` `cache=none` baseline and `81.258s` `cache=writeback`
throughput probe into the same band as the optimized Linux FUSE path, without
requiring writeback caching.

| Output root | QEMU cache | QEMU aio | Block queues | Bazel elapsed | Input fetch p50 | Process/io p50 | Process/io p95 | Fixed overhead p50 | Fixed overhead p95 |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `/var/home/wgray/actiond-llvm-smokes/qemu-q35-none-iouring-j16-20260525-165821` | `none` | `io_uring` | default | `55.682s` | `0.826ms` | `40.761ms` | `1656.229ms` | `6.564ms` | `30.501ms` |
| `/var/home/wgray/actiond-llvm-smokes/qemu-q35-none-iouring-j16-repeat-20260525-170026` | `none` | `io_uring` | default | `57.063s` | `0.790ms` | `42.458ms` | `1678.937ms` | `6.052ms` | `35.304ms` |
| `/var/home/wgray/actiond-llvm-smokes/qemu-q35-none-defaultaio-j16-20260525-171006` | `none` | default `io_uring` | default | `62.162s` | `0.712ms` | `40.785ms` | `1863.243ms` | `7.621ms` | `40.846ms` |
| `/var/home/wgray/actiond-llvm-smokes/qemu-q35-none-defaultaio-j16-repeat-20260525-171324` | `none` | default `io_uring` | default | `58.491s` | `0.762ms` | `37.253ms` | `1684.048ms` | `5.064ms` | `25.833ms` |
| `/var/home/wgray/actiond-llvm-smokes/qemu-q35-none-iouring-queues16-j16-20260525-172553` | `none` | default `io_uring` | 16 | `54.117s` | `0.733ms` | `34.017ms` | `1606.596ms` | `5.279ms` | `27.445ms` |
| `/var/home/wgray/actiond-llvm-smokes/qemu-q35-none-iouring-queues16-j16-repeat-20260525-172909` | `none` | default `io_uring` | 16 | `56.711s` | `0.769ms` | `45.859ms` | `1630.011ms` | `5.747ms` | `31.623ms` |
| `/var/home/wgray/actiond-llvm-smokes/qemu-q35-none-iouring-queues8-j16-20260525-173314` | `none` | default `io_uring` | 8 | `55.144s` | `0.770ms` | `36.861ms` | `1591.519ms` | `6.068ms` | `31.547ms` |
| `/var/home/wgray/actiond-llvm-smokes/qemu-q35-none-iouring-queues4-j16-20260525-173113` | `none` | default `io_uring` | 4 | `56.501s` | `0.819ms` | `40.189ms` | `1621.113ms` | `5.440ms` | `35.292ms` |
| `/var/home/wgray/actiond-llvm-smokes/qemu-q35-writeback-iouring-j16-20260525-165401` | `writeback` | `io_uring` | default | `53.217s` | `0.742ms` | `34.489ms` | `1590.465ms` | `5.644ms` | `24.625ms` |
| `/var/home/wgray/actiond-llvm-smokes/qemu-q35-writeback-iouring-j16-repeat-20260525-165616` | `writeback` | `io_uring` | default | `58.311s` | `0.754ms` | `41.177ms` | `1703.801ms` | `5.495ms` | `36.059ms` |

`cache=none,aio=io_uring` is the preferred default because it gets the large
I/O backend win while preserving the stricter cache mode. `cache=writeback`
remains available as an explicit flag for local experiments where host-crash
durability of the VM disk image is less important than a possible small
throughput gain. Explicit virtio-blk multiqueue probes with
`--qemu-block-queues=4|8|16` were valid and the guest reported the requested
queue counts, but the gains were small and noisy, so block queue count remains
an explicit tuning knob instead of a default. A q35 CPU override probe with
`host,migratable=off,+invtsc` measured `59.592s`, so it was not kept.

## Latest Native Linux FUSE Result

These runs use the Linux FUSE actiondfs smoke wrapper, not `serve-vm`:

```bash
ACTIOND_LLVM_LINUX_MODE=fuse e2e/run_llvm_linux_smoke.sh
```

The first set was collected on 2026-05-24 after persistent FUSE registry mode,
cached directory templates, stable immutable input file nodes, and lazy CAS blob
open validation. Later the measured invocation was changed to always pass
`--noremote_accept_cached`, avoiding about 1,998 measured action-cache miss
RPCs, and the Linux FUSE smoke default was tuned to `ACTIOND_LLVM_SMOKE_JOBS=16`
with a 16-thread helper. The helper now disables its own FUSE stats atomics by
default; set `ACTIOND_ACTIONDFS_FUSE_STATS=1` when those exit counters are more
important than the hot-path cost. The benchmarked server/helper binaries use
optimized Zig `ReleaseFast` and `-mcpu=native`.

Each checked run parsed `1,998` execute records, all in `actiondfs_strict` mode,
with no `overlayfs`, `mount_overlay`, or `actiondfs_overlay` matches in the
checked logs.

| Output root | Bazel elapsed | Input fetch p50 | Process/io p50 | Process/io p95 | Fixed overhead p50 | Fixed overhead p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-nostats-threads16-20260524-174012` | `54.246s` | `2.425ms` | `45.040ms` | `1801.146ms` | `7.830ms` | `14.604ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-nostats-threads16-repeat-20260524-174640` | `58.050s` | `2.392ms` | `44.192ms` | `1973.814ms` | `7.578ms` | `15.054ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-default-20260524-175318` | `56.736s` | `2.429ms` | `43.594ms` | `1887.882ms` | `7.654ms` | `14.753ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-copyrange-nostats1-20260524-try3-4` | `56.179s` | `2.457ms` | `45.691ms` | `1849.581ms` | `8.418ms` | `16.013ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-copyrange-nostats2-20260524-try3-4` | `56.112s` | `2.535ms` | `44.718ms` | `1879.764ms` | `8.394ms` | `16.857ms` |

The copy-file-range runs above include a FUSE `copy_file_range` output fast
path and a ByteStream write parser fast path that avoids copying complete gRPC
records into a pending buffer when no partial record is buffered. They used
fresh Bazel workload output bases via
`ACTIOND_LLVM_SMOKE_BAZEL_STARTUP_FLAGS=--output_base=...` and
`ACTIOND_LLVM_SMOKE_SKIP_CLEAN=1` because a shared-output-base
`bazel clean --expunge` run stalled for more than four minutes before any
measured remote action started. A stats-enabled diagnostic run at
`/var/mnt/dev/actiond-worker/llvm-smokes/fuse-copyrange-stats2-20260524-try3-4`
reported `3834` FUSE `copy_file_range` operations, `31180842` copied bytes,
and zero fallbacks or failures, but elapsed `62.059s` with stats atomics
enabled. The no-stats wall time stayed in the prior `54-58s` band because
output collection was already a small part of the workload.

The current FUSE helper also returns `FOPEN_NOFLUSH` for normal file opens. The
helper's `flush` handler was already a no-op, so this removes close-time FUSE
round trips and keeps more useful kernel-side file data cached. Two clean
no-stats confirmation runs after killing stale benchmark Bazel servers measured:

| Output root | Bazel elapsed | Input fetch p50 | Process/io p50 | Process/io p95 | Fixed overhead p50 | Fixed overhead p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-noflush2-20260525-try-order` | `53.693s` | `2.494ms` | `45.206ms` | `1705.075ms` | `8.130ms` | `16.077ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-noflush3-20260525-try-order` | `54.231s` | `2.381ms` | `41.806ms` | `1811.800ms` | `8.071ms` | `15.568ms` |

A stats-enabled diagnostic run at
`/var/mnt/dev/actiond-worker/llvm-smokes/fuse-noflush-stats-20260525-try-order`
measured `55.445s` and showed total FUSE requests down to `2,537,951`, with the
generic `other` bucket down to `487,891` and read requests down to `11,143`.
The comparable pre-`NOFLUSH` stats diagnostic had `3,090,232` total requests,
`1,032,901` `other` requests, and `17,569` read requests.

A follow-up on 2026-05-25 removed per-request clock reads from the no-stats
worker path and writes generic FUSE replies with `writev`, avoiding one
allocation and payload copy per non-scratch reply. The earlier interrupted
`writev` retries are excluded; after the system sleep and CPU policy changes
were out of the way, the clean retry measured:

| Output root | Bazel elapsed | Input fetch p50 | Process/io p50 | Process/io p95 | Fixed overhead p50 | Fixed overhead p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-notiming1-20260525` | `54.178s` | `2.539ms` | `41.110ms` | `1712.956ms` | `8.068ms` | `16.232ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-notiming2-20260525` | `54.504s` | `2.491ms` | `44.394ms` | `1696.185ms` | `7.399ms` | `14.330ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-writev1-20260525` | `55.745s` | `2.365ms` | `45.575ms` | `1689.485ms` | `8.301ms` | `15.461ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-writev4-20260525` | `53.147s` | `2.347ms` | `42.529ms` | `1682.152ms` | `8.201ms` | `15.479ms` |

One more pass on 2026-05-25 looked at the remaining FUSE read path and small
HTTP/2 allocation overhead. Reusing one inbound frame payload buffer per
connection, stack-encoding small response header blocks, setting TCP_NODELAY on
accepted gRPC sockets, and using the scratch read path for CAS reads below
`64KiB` produced these checked runs:

| Output root | Bazel elapsed | Input fetch p50 | Process/io p50 | Process/io p95 | Fixed overhead p50 | Fixed overhead p95 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-framebuf1-20260525` | `53.716s` | `2.482ms` | `44.480ms` | `1707.787ms` | `7.795ms` | `15.025ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-splice64k1-20260525` | `52.746s` | `2.408ms` | `37.619ms` | `1728.544ms` | `7.225ms` | `14.257ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-finalcand2-20260525` | `54.441s` | `2.408ms` | `57.251ms` | `2081.572ms` | `8.615ms` | `17.042ms` |

The `64KiB` splice threshold is now the default. Small reads are cheaper through
the helper's existing `pread` scratch-buffer reply path than through a
pipe/splice round trip, while larger reads still use splice. A no-splice probe
landed at `54.780s`, and a `256KiB` threshold probe landed at `56.994s`, so
neither was kept. A first final-candidate run at `63.482s` was repeated because
process/io, fork, and setup medians all inflated together under host load; the
second run above is the usable confirmation. The checked logs for these runs
again had no `overlayfs`, `mount_overlay`, or `actiondfs_overlay` matches.

A stats-enabled passthrough retry at
`/var/mnt/dev/actiond-worker/llvm-smokes/fuse-pt-current-stats-20260525-132425`
measured `54.537s` with the current correctness-preserving policy. The helper
negotiated Linux FUSE passthrough, but LLVM's input trees marked every attempted
CAS open executable, so passthrough remained unused: `opens=0`,
`skip_executable=468838`. Unsafe content-classification probes that allowed JSON
config files to passthrough failed during warmup with `open(...): EIO`, including
variants with `FOPEN_DIRECT_IO` and with executable-marked backing blobs chmodded
to `0555`, so no passthrough policy change was kept.

The immediate predecessor with only persistent FUSE plus parsed directory
template caching was `/tmp/actiond-llvm-linux-smoke.ZSLnna`: `98.646s`,
`0.800ms` input fetch p50, `84.237ms` process/io p50, `4,186,541` FUSE read
requests, and `310.03GB` of FUSE read replies. The stable-file-node change
therefore moved repeated CAS input reads into the kernel's FUSE page cache by
reusing one inode identity per immutable `(name, digest, size, executable)`
input file across actions.

The immediate predecessor with stable file nodes but eager CAS blob validation
on every FUSE `open` was `/tmp/actiond-llvm-linux-smoke.UDsrv1`: `80.089s`,
`0.763ms` input fetch p50, `26.952ms` process/io p50, `12,757` FUSE read
requests, `358.44MB` of FUSE read replies, and `480,761` CAS blob opens. Lazy
open validation keeps missing-blob detection on the actual read path and avoids
hundreds of thousands of open/close pairs for already-described immutable CAS
inputs.

A `jobs=20` probe landed at `249.153s`, but it was contaminated by unrelated
slug Rust/C builds and system load above 70; it is recorded only as evidence
against raising the default while the host is busy. A zero-open/FUSE
`NO_OPEN_SUPPORT` probe landed at `91.826s` and regressed child setup p95 to
`165.807ms`, so it is not enabled by default.

## Linux Host Staged-QEMU Check

These runs were collected on 2026-05-24 on the Linux host using the
`qemu-system-x86_64` binary from the pending rpm-ostree deployment. The booted
`/usr` did not yet contain QEMU on `PATH`, so the runner used
`ACTIOND_LLVM_VM_SMOKE_QEMU` plus `LD_LIBRARY_PATH` pointed at the staged
deployment. QEMU started with `-machine q35,accel=kvm -cpu host -smp 8`.

Both measured builds parsed `1,998` execute records, used `1,998` remote
actions, and the checked logs had no `overlayfs`, `mount_overlay`, or
`actiondfs_overlay` matches.

| Output root | Warmup elapsed | Bazel elapsed | Input fetch p50 | Process/io p50 | Process/io p95 | Fixed overhead p50 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/var/mnt/dev/actiond-worker/llvm-smokes/qemu-staged-20260524-134439` | `67.036s` | `89.317s` | `0.498ms` | `21.615ms` | `1180.241ms` | `3.637ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/qemu-staged-repeat-20260524-135527` | `65.635s` | `85.494s` | `0.489ms` | `21.802ms` | `1196.735ms` | `3.169ms` |

Current persistent Linux FUSE is still faster end-to-end on this host
(`52.746-54.441s` in the latest checked 16-job runs) even though the VM path has
lower median per-action `process/io`. This points at aggregate remote
execution, bridge, or guest scheduling overhead as the next VM-side comparison
point, not input materialization.

## Run Comparison

This compares the previous VFS-backed `copy_file_range` run, where the
actiondfs stage lived on `/work` tmpfs, against the current run, where the
stage lives under `/cas/actiondfs-stage` on the VM ext4 CAS image and output
collection can promote same-filesystem staged files into CAS by rename.

| Metric            | Previous |     New |   Delta |
| ----------------- | -------: | ------: | ------: |
| VM measured build |  60.358s | 59.657s | -0.701s |
| VM warmup         |  57.041s | 55.146s | -1.895s |

| VM Stage                | Previous Mean |  New Mean |     Delta |
| ----------------------- | ------------: | --------: | --------: |
| total                   |     194.454ms | 191.940ms |  -2.514ms |
| input fetch/materialize |       0.177ms |   0.769ms |  +0.592ms |
| execute                 |     193.525ms | 190.507ms |  -3.018ms |
| output upload/collect   |       0.751ms |   0.664ms |  -0.087ms |

## VM Stage Timing

All values are milliseconds.

| Stage                   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| ----------------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| total                   | 3.270 | 15.173 | 18.612 | 28.997 | 1110.783 | 191.940 | 6422.421 |
| input fetch/materialize | 0.459 |  0.633 |  0.661 |  0.753 |    1.247 |   0.769 |   13.720 |
| execute                 | 2.010 | 14.190 | 17.550 | 27.497 | 1108.179 | 190.507 | 6418.218 |
| output upload/collect   | 0.085 |  0.188 |  0.209 |  0.354 |    1.950 |   0.664 |  196.492 |

## Runner Timing

`process/io` includes the action process runtime, stdout/stderr drain, and lazy
filesystem reads issued by the action through the mounted actiondfs tree.

| Runner Stage   |   Min |    p25 |    p50 |    p75 |      p95 |    Mean |      Max |
| -------------- | ----: | -----: | -----: | -----: | -------: | ------: | -------: |
| parent prepare | 0.076 |  0.111 |  0.123 |  0.141 |    0.280 |   0.147 |    1.300 |
| fork           | 0.189 |  0.384 |  0.412 |  0.519 |    4.190 |   0.875 |    8.956 |
| child setup    | 0.002 |  0.196 |  0.381 |  1.876 |    4.646 |   1.202 |    9.335 |
| process/io     | 0.071 | 12.023 | 15.826 | 25.333 | 1103.368 | 188.210 | 6413.176 |
| wait           | 0.000 |  0.000 |  0.000 |  0.007 |    0.015 |   0.006 |    2.646 |
| stdio digest   | 0.000 |  0.000 |  0.001 |  0.001 |    0.001 |   0.001 |    0.124 |

## VM Bridge Timing

These counters measure the raw TCP-to-vsock pump in `darwin-actiond serve-vm`.
The elapsed column is connection lifetime, not CPU time.

- Bridge connections logged: `2`
- Total client to guest bytes: `28.47 MiB`
- Total guest to client bytes: `37.76 MiB`
- Pump errors: read=`0`, write=`0`

| Bridge Metric          |       Min |       p25 |       p50 |       p75 |       p95 |      Mean |       Max |
| ---------------------- | --------: | --------: | --------: | --------: | --------: | --------: | --------: |
| connection elapsed     | 58487.024 | 58945.210 | 59403.396 | 59861.582 | 60228.131 | 59403.396 | 60319.768 |
| client to guest KiB    |   10708.4 |   12643.2 |   14577.9 |   16512.7 |   18060.5 |   14577.9 |   18447.5 |
| guest to client KiB    |   17063.6 |   18197.9 |   19332.2 |   20466.5 |   21374.0 |   19332.2 |   21600.8 |
| client to guest reads  |      8447 |      8554 |      8661 |      8768 |      8854 |    8661.0 |      8875 |
| client to guest writes |      8446 |      8553 |      8660 |      8767 |      8853 |    8660.0 |      8874 |
| guest to client reads  |     21741 |     22158 |     22575 |     22992 |     23326 |   22575.0 |     23409 |
| guest to client writes |     21740 |     22157 |     22574 |     22991 |     23325 |   22574.0 |     23408 |

## actiondfs Counters

These counters are from `/proc/actiondfs_stats` at the end of the VM run.

| Counter                   |        Value |
| ------------------------- | -----------: |
| mounts                    |         4123 |
| root directory parses     |         4123 |
| cached directory hits     |       155471 |
| cached directory misses   |         5223 |
| lookups                   |      1407093 |
| lookup hits               |       842187 |
| lookup negative           |       564906 |
| blob open attempts        |       453362 |
| blob path cache hits      |       437047 |
| blob path cache misses    |         6969 |
| blob path cache inserts   |         6969 |
| blob path cache evictions |            0 |
| blob path cache races     |            0 |
| node blob cache hits      |        28555 |
| node blob cache misses    |       440188 |
| backing reads             |       415500 |
| backing read bytes        |   1303976522 |
| splice reads              |            0 |
| splice read bytes         |            0 |
| mmap calls                |        53243 |
| mmap bytes                | 1901688811520 |
| mmap failures             |            0 |
| directory blob reads      |         9344 |
| directory blob bytes      |      3182957 |

## actiondfs Staged Counters

| Counter                         |      Value |
| ------------------------------- | ---------: |
| stage parent path lookups       |       7852 |
| stage parent path errors        |          0 |
| stage child lookups             |        214 |
| stage child lookup hits         |         16 |
| stage child lookup negative     |        198 |
| stage child lookup errors       |          0 |
| stage ensure dir calls          |      12182 |
| stage ensure dir components     |     103548 |
| stage ensure dir existing       |     103548 |
| stage ensure dir created        |          0 |
| stage ensure dir errors         |          0 |
| stage inode lookups             |    1407093 |
| stage inode lookup hits         |      35540 |
| stage inode lookup negative     |    1371553 |
| stage inode lookup errors       |          0 |
| stage inode input dir merges    |      18402 |
| stage backing open attempts     |      41054 |
| stage backing open failures     |          0 |
| stage read calls                |          0 |
| stage read bytes                |          0 |
| stage write calls               |      37194 |
| stage write bytes               |  106358935 |
| stage splice read calls         |          0 |
| stage splice read bytes         |          0 |
| stage mmap calls                |         32 |
| stage mmap bytes                |    7905280 |
| stage mmap failures             |          0 |
| stage create calls              |      11984 |
| stage create success            |      11984 |
| stage create failures           |          0 |
| stage mkdir calls               |        198 |
| stage mkdir success             |        198 |
| stage mkdir failures            |          0 |
| stage unlink calls              |         16 |
| stage unlink success            |         16 |
| stage unlink failures           |          0 |
| stage rmdir calls               |          0 |
| stage rename calls              |       3819 |
| stage rename success            |       3819 |
| stage rename failures           |          0 |
| stage setattr size calls        |       3876 |
| stage setattr size success      |       3876 |
| stage setattr size failures     |          0 |
| stage readdir calls             |          0 |
| stage copy_file_range attempts  |       3828 |
| stage copy_file_range success   |       3828 |
| stage copy_file_range bytes     |   31630764 |
| stage copy_file_range fallbacks |          0 |

## CAS Put-File Promotion Counters

These counters are VM-lifetime counters collected at the same time as the
actiondfs stats, so they include both warmup and measured builds.

| Counter                                      |    Value |
| -------------------------------------------- | -------: |
| CAS put file calls                           |     7949 |
| CAS put file promote attempts                |     7949 |
| CAS put file promote success                 |     2089 |
| CAS put file promote existing blob           |     5860 |
| CAS put file promote bytes                   | 38021375 |
| CAS put file promote cross-device fallbacks  |        0 |
| CAS put file promote permission fallbacks    |        0 |
| CAS put file copy calls                      |        0 |
| CAS put file copy bytes                      |        0 |

## Staged Output Analysis

| Derived Metric                                |     Value |
| --------------------------------------------- | --------: |
| staged write bytes                            | 101.43MiB |
| copy_file_range bytes                         |  30.17MiB |
| CAS promote bytes                             |  36.26MiB |
| average bytes per staged write call           |   2859.6 |
| staged writes per created file                |     3.10 |
| average bytes per copy_file_range success     |   8263.0 |
| copy_file_range fallback rate                 |    0.00% |
| CAS put-file actual rename rate               |   26.28% |
| CAS put-file existing-blob rate               |   73.72% |
| CAS put-file copy fallback rate               |    0.00% |
| backing opens beyond staged write calls       |     3860 |
| stage ensure dir components per ensure call   |     8.50 |
| staged inode lookup hit rate                  |    2.53% |
| staged inode lookup negative rate             |   97.47% |

## Notes

The `execute` bucket dominates this workload. With lazy actiondfs inputs, most
filesystem metadata and mapped-file access happen while the child process is
running, so that time appears in `execute`, primarily in `process/io`, rather
than in `input fetch/materialize`.

This run validates the actiondfs `copy_file_range` path and the ext4-backed
stage under the concurrent `copy_to_directory` workload used by the LLVM smoke.
The actiondfs stage is now under `/cas/actiondfs-stage`, so staged outputs and
CAS blobs live on the same ext4 filesystem inside the guest.

Go's `io.Copy` attempted `copy_file_range` `3828` times. The actiondfs hook
handled all `3828` attempts and copied `30.17MiB`. For CAS or staged actiondfs
source files, actiondfs opens the real source backing file and the real staged
output file, then calls `vfs_copy_file_range`. There is no bounded in-kernel
buffered fallback in actiondfs; a selected backing-copy failure increments
`stage_copy_file_range_fallbacks` and is treated as an error.

CAS output collection saw `7949` `putFile` calls during the VM lifetime. All of
them attempted same-filesystem promotion; `2089` were actual staged-file renames
into CAS, `5860` found that the destination blob already existed, and none fell
back to byte-copying. The actual rename path promoted `36.26MiB` of output data
into CAS without a second file copy.

The staged counters show that `copy_file_range` moved part of the
`copy_to_directory` traffic out of userspace read/write loops. Staged write
bytes were `101.43MiB`, while another `30.17MiB` was accounted by
`stage_copy_file_range_bytes`. The `3860` backing opens beyond staged write
calls are the `3828` copy-file-range output opens plus `32` staged mmap opens.

Directory pre-creation is doing its job: `stage_ensure_dir_created=0`, while
`stage_ensure_dir_existing=103548`. The remaining cost is repeated validation
and walking of already-existing parent paths.

Staged lookup is mostly negative: `35540` hits versus `1371553` misses. That is
expected for overlay-style lookup, but it makes negative-stage lookup caching or
directory-level "has staged children" filtering worth measuring. The hot
negative counter itself is also expensive instrumentation; if these stats stay
long term, prefer derived values or per-CPU counters on this path.

The raw VM bridge moved about 66 MiB across two long-lived measured
connections, so the dumb TCP-to-vsock pump is not the visible bottleneck in
this run. Most time remains in `process/io`, which includes compiler runtime
plus lazy actiondfs filesystem work issued by the compiler itself.

The mac-host baseline was skipped for this VM-focused actiondfs copy-file-range
check.
The previous checked-in full comparison had matching measured action counts:
`2310` total processes and `2106` action executions for both VM and mac-host.
