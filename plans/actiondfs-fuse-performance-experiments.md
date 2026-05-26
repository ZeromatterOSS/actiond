# actiondfs FUSE Performance Experiments

## Goal

Explain why the native Linux FUSE actiondfs experiment is slower than the
Linux QEMU/kernel actiondfs path, then identify whether FUSE can become a
useful lighter-weight path or should remain a proof-of-concept/debug fallback.

The current evidence is mixed. Earlier native FUSE `ReleaseFast -mcpu=native`
LLVM smoke runs, before removing the stock overlayfs layer, measured:

- `190.174s`
- `134.464s`
- `141.914s`

The stable band was closer to `134-142s`; the `190s` run likely reflects host
load variance. In the stable runs, input fetch/materialization p50 was about
`15ms`, while action `process/io` p50 was about `140-150ms`. QEMU/kernel
actiondfs previously measured around `100-107s`, with input fetch p50 around
`0.3-0.4ms` and process/io p50 around `34-38ms`.

After removing overlayfs from the native FUSE path, the LLVM smoke completes
with all measured actions using `input_mode=actiondfs_strict`. The first
complete no-overlay runs regressed input fetch/materialization to about
`87-91ms` p50. Instrumentation isolated that to the FUSE-only direct executable
staging path: each action copied `argv[0]` out of CAS into the per-action stage
tree before `execve`.

The current branch removes that copy and executes the resolved input path
directly from the strict FUSE workspace. The full LLVM FUSE smoke now measures
`138.971s`, with input fetch/materialization p50 at `15.921ms` and all measured
actions still in strict mode. Remaining gap is in the action process/read path
and in the per-action FUSE helper/mount startup, not in overlayfs or executable
staging.

Post-rebase measurements on 2026-05-22 with the Linux x86_64 LLVM smoke,
`-c opt --strip=always --stripopt=--strip-all`, `jobs=8`, and Linux x86_64
musl target/host platforms. The `native FUSE, no overlayfs` row was collected
before verifying that Bazel `-c opt` was also optimizing Zig, so keep it as a
diagnostic no-overlay datapoint rather than the final optimized comparison:

| mode | output root | Bazel elapsed | input fetch p50 | process/io p50 | process/io p95 |
| --- | --- | ---: | ---: | ---: | ---: |
| native FUSE | `/tmp/actiond-bench-fuse-manual-1b-20260522-154808` | `133.435s` | `16.029ms` | `161.091ms` | `1465.326ms` |
| native FUSE | `/tmp/actiond-bench-fuse-manual-2-20260522-155338` | `130.898s` | `15.840ms` | `164.781ms` | `1448.923ms` |
| native FUSE, no overlayfs | `/tmp/actiond-llvm-linux-fuse-nolower.XJLGep` | `172.318s` | `91.082ms` | `182.420ms` | `1730.898ms` |
| native FUSE, no overlayfs, optimized Zig native | `/tmp/actiond-llvm-linux-fuse-optzig-sudo-20260522-205522` | `165.388s` | `87.299ms` | `152.939ms` | `1702.266ms` |
| native FUSE, no overlayfs, optimized Zig native | `/tmp/actiond-llvm-linux-fuse-optzig-sudo-20260522-210249` | `144.263s` | `89.476ms` | `146.466ms` | `1461.477ms` |
| native FUSE, no overlayfs, sendfile executable staging | `/tmp/actiond-llvm-linux-smoke.IsyJ8C` | `159.902s` | `93.810ms` | `147.190ms` | `1676.366ms` |
| native FUSE, no overlayfs, direct FUSE exec | `/tmp/actiond-llvm-linux-smoke.hidBqt` | `138.971s` | `15.921ms` | `147.493ms` | `1753.999ms` |
| QEMU q35/KVM `cache=none,aio=io_uring` | `/tmp/actiond-bench-qemu-1-20260522-155837` | `130.321s` | `0.301ms` | `22.695ms` | `1793.560ms` |

The QEMU run was started from a fresh post-expunge worker, so its server/kernel
bundle build time is not part of the parsed smoke elapsed. A second QEMU pass
should be collected before making a final QEMU/FUSE comparison because this host
has unrelated background workloads.

Follow-up on 2026-05-22 found that `-c opt` alone still left rules_zig actions
at `-O Debug`. The repo now appends Zig `ReleaseFast` for `-c opt`, and the LLVM
benchmark runners force both `--@rules_zig//zig/settings:mode=release_fast` and
`--@rules_zig//zig/settings:zigopt=-mcpu=native` for the benchmarked
server/helper binaries. Two optimized FUSE reruns completed after enabling the
specific passwordless sudo rule. Both parsed 1,998 execute records and all were
`input_mode=actiondfs_strict`; measured logs had no overlay input-mode or
overlayfs matches. Direct Linux materialized mode without sudo still fails child
setup at `unshare_namespaces errno=PERM`, and the QEMU runner built the
optimized VM standalone package but `serve-vm` failed before listening because
`qemu-system-x86_64` was not present on `PATH`.

## Root Cause Found

The regression from the strict no-overlay FUSE path was not stock overlayfs and
was not Zig debug code. The FUSE path resolved the executable input and then
copied that CAS blob into the writable stage directory so Linux could execute
it from the stage tree. On the LLVM warmup target, that path measured:

- staged executable warmup: `/tmp/actiond-llvm-linux-smoke.8qi3KN`
  - Bazel elapsed `139.387s`
  - input fetch/materialization p50 `94.268ms`
  - setup instrumentation p50: `exec_stage_ns=80.056ms`,
    `fuse_start_ns=14.050ms`
- direct FUSE executable warmup: `/tmp/actiond-llvm-linux-smoke.VsPcMV`
  - Bazel elapsed `97.344s`
  - input fetch/materialization p50 `14.640ms`
  - setup instrumentation p50: `exec_stage_ns=0`,
    `fuse_start_ns=14.321ms`

The direct FUSE exec full smoke parsed 1,998 measured actions, all
`input_mode=actiondfs_strict`, with no `overlayfs`, `mount_overlay`, or
`actiondfs_overlay` matches in the output directory. Setup instrumentation in
the measured log showed:

- `input_fetch_ns` p50 `15.919ms`, p95 `19.469ms`
- `fuse_start_ns` p50 `15.449ms`, p95 `18.664ms`
- `exec_stage_ns` p50/p95/max `0`

The helper counters for the same full smoke reported 249 helper exits,
331,490 FUSE requests, 228,713 read requests, and 18.589GB read through FUSE.
That explains why the remaining gap is mostly in `process/io`: after setup, the
compiler still obtains LLVM inputs and the executable through userspace FUSE
round trips instead of the VM path's kernel actiondfs backing-file reads,
splice, mmap, and VM-lifetime caches.

## 2026-05-23 Read-Path And Threading Experiments

The helper now returns an opaque FUSE file handle that points directly at the
opened node, so `read`, `write`, and `readdir` do not need to reacquire the
global tree lock just to translate `nodeid` back to a `Node`. CAS blob fds are
also cached behind an atomic fast path: the first open still uses the per-node
lock, but hot reads only load the cached fd instead of taking that lock for
every FUSE read request.

This is a coordination cleanup, not the main performance fix. The LLVM smoke
still spends almost all visible time in action `process/io`, and helper stats
still show hundreds of thousands of FUSE read requests moving tens of GB through
userspace. The code path is no longer doing an exclusive tree-lock lookup and a
per-node lock on every read, but it is still paying the FUSE request/reply and
userspace scheduling cost for each read.

Thread-count benchmarking with optimized Zig native builds:

| helper threads | output root | Bazel elapsed | input fetch p50 | process/io p50 | process/io p95 |
| ---: | --- | ---: | ---: | ---: | ---: |
| 8 | `/tmp/actiond-llvm-linux-smoke.ZdNg0K` | `134.013s` | `15.499ms` | `124.795ms` | `1706.852ms` |
| 4 | `/tmp/actiond-llvm-linux-smoke.QYcHEX` | `134.239s` | `15.455ms` | `120.050ms` | `1750.450ms` |
| 2 | `/tmp/actiond-llvm-linux-smoke.vOBlda` | `138.728s` | `15.292ms` | `127.260ms` | `1773.048ms` |
| 4 + passthrough negotiation stats | `/tmp/actiond-llvm-linux-smoke.BoB877` | `128.861s` | `15.832ms` | `122.321ms` | `1622.328ms` |

These results were later superseded by persistent registry mode, stable file
nodes, lazy CAS blob open validation, and the 2026-05-24 benchmark/RPC fixes
below. The remaining useful takeaway is that too few helper workers can sit
below the knee for this workload, while excessive workload parallelism causes
large child setup and process scheduling tails.

## 2026-05-24 Benchmark RPC And Default-Tuning Experiments

The LLVM Linux FUSE smoke previously accepted remote action-cache hits during
the measured invocation whenever a warmup target was configured. In this
actiond-as-cache setup that did not produce hits; it produced about 1,998
`GetActionResult` `NOT_FOUND` RPCs in the measured build. The smoke now always
passes `--noremote_accept_cached` for the measured build, matching the intent of
measuring executor behavior rather than action-cache misses.

The branch also shares a process-lifetime CAS presence index between
FindMissingBlobs, BatchUpdateBlobs, ByteStream writes, and action output upload
paths. This avoids repeated filesystem existence checks for digests already
known to be present in this worker. The change is conservative, but the LLVM
smoke did not show a clear wall-time win by itself under host load.

Hot-path FUSE stats atomics were measurable once the read path was otherwise
reduced. The helper now keeps FUSE stats disabled by default and enables them
only with `ACTIOND_ACTIONDFS_FUSE_STATS=1`; `ACTIOND_ACTIONDFS_FUSE_DISABLE_STATS`
can still force them off for wrapper-driven experiments. The helper default
worker count is now `16`, and the Linux FUSE LLVM smoke defaults to
`ACTIOND_LLVM_SMOKE_JOBS=16`. Benchmark server/helper builds continue to force
Zig `ReleaseFast` and `-mcpu=native`.

Representative FUSE LLVM smoke runs after these changes:

| configuration | output root | Bazel elapsed | fixed overhead p50 | fixed overhead p95 | process/io p50 | notes |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| jobs=8, no measured AC lookup | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-noac-20260524-165150` | `78.024s` | `4.269ms` | n/a | `26.937ms` | First run after removing measured `GetActionResult` misses |
| jobs=16, helper threads=16, stats off | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-nostats-threads16-20260524-174012` | `54.246s` | `7.830ms` | `14.604ms` | `45.040ms` | Best clean run |
| jobs=16, helper threads=16, stats off repeat | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-nostats-threads16-repeat-20260524-174640` | `58.050s` | `7.578ms` | `15.054ms` | `44.192ms` | Confirmation run |
| default settings after patch | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-default-20260524-175318` | `56.736s` | `7.654ms` | `14.753ms` | `43.594ms` | No benchmark env other than output root |
| jobs=16, zero-open enabled | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-nostats-threads16-zeroopen-20260524-174308` | `91.826s` | `10.361ms` | `195.950ms` | `64.117ms` | Rejected; child setup p95 regressed to `165.807ms` |
| jobs=20 | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-default-jobs20-20260524-175732` | `249.153s` | `28.587ms` | `686.759ms` | `205.661ms` | Contaminated by unrelated slug Rust/C builds; do not use for defaults |

Follow-up experiments for the remaining output/RPC overhead tried two more
low-risk hot-path reductions:

- ByteStream upload parsing now reads complete gRPC records directly from the
  received slice whenever no previous partial record is buffered, instead of
  first appending every chunk into a pending buffer.
- The FUSE helper now handles Linux `FUSE_COPY_FILE_RANGE` and
  `FUSE_COPY_FILE_RANGE_64`, copying from immutable CAS/staged source fds to
  staged output fds inside the helper. That avoids routing action-level
  `copy_file_range` calls through the slower FUSE read/write fallback.

A stats-enabled diagnostic run at
`/var/mnt/dev/actiond-worker/llvm-smokes/fuse-copyrange-stats2-20260524-try3-4`
proved the output fast path is exercised: `3834` `copy_file_range` operations,
`31180842` copied bytes, and zero fallbacks or failures. Its wall time was
`62.059s` with stats atomics enabled, so it is diagnostic rather than a default
comparison.

Two no-stats runs with the same optimized server/helper build flags measured:

| configuration | output root | Bazel elapsed | fixed overhead p50 | fixed overhead p95 | process/io p50 | output collect mean |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| copy-file-range + ByteStream parser fast path | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-copyrange-nostats1-20260524-try3-4` | `56.179s` | `8.418ms` | `16.013ms` | `45.691ms` | `0.416ms` |
| copy-file-range + ByteStream parser fast path repeat | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-copyrange-nostats2-20260524-try3-4` | `56.112s` | `8.394ms` | `16.857ms` | `44.718ms` | `0.416ms` |

Those results are correctness-positive but performance-neutral for the full
LLVM smoke. Output collection was already about `0.4ms` mean per action, so
removing extra copies there does not move wall time. The stable remaining cost
is still in action process runtime and FUSE metadata/read behavior, not output
upload. The runs used fresh Bazel workload output bases with
`ACTIOND_LLVM_SMOKE_BAZEL_STARTUP_FLAGS=--output_base=...` and
`ACTIOND_LLVM_SMOKE_SKIP_CLEAN=1`; a shared-output-base `bazel clean --expunge`
attempt stalled for more than four minutes before the measured action phase.

A 2026-05-24 ordered pass through the remaining FUSE ideas found one small
additional win and several non-wins:

| experiment | output root | Bazel elapsed | fixed overhead p50 | process/io p50 | result |
| --- | --- | ---: | ---: | ---: | --- |
| passthrough stats check | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-passthrough-stats-20260525-try-order` | `58.372s` | n/a | n/a | Passthrough negotiated but `opens=0`; every attempted CAS open was skipped as executable |
| force executable passthrough | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-passthrough-exec-stats-20260525-try-order` | failed | n/a | n/a | First warmup action failed with `execve EIO`; still not viable |
| staged fd cached on node | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-stagefd1-20260525-try-order` | failed | n/a | n/a | Long-lived output fd cache exhausted/leaked fds and produced `OpenFailed` |
| per-open staged fd handle | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-openhandle1-20260525-try-order` | `55.518s` | n/a | `44.445ms` | Correctness cleanup; performance-neutral |
| per-open staged fd handle repeat | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-openhandle2-20260525-try-order` | `56.305s` | n/a | `42.760ms` | Confirmed neutral |
| helper threads=32 | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-threads32-20260525-try-order` | `60.274s` | `9.412ms` | `52.046ms` | Worse than the 16-thread default |
| stack-buffer small FUSE replies | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-stackreply1-20260525-try-order` | `69.496s` | `9.789ms` | `54.171ms` | Rejected |
| stack-buffer small FUSE replies repeat | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-stackreply2-20260525-try-order` | `60.109s` | `9.078ms` | `48.094ms` | Rejected |
| `FOPEN_NOFLUSH` | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-noflush2-20260525-try-order` | `53.693s` | `8.130ms` | `45.206ms` | Kept |
| `FOPEN_NOFLUSH` repeat | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-noflush3-20260525-try-order` | `54.231s` | `8.071ms` | `41.806ms` | Confirmed |
| `FOPEN_NOFLUSH`, stats enabled | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-noflush-stats-20260525-try-order` | `55.445s` | `8.610ms` | n/a | Diagnostic only |
| `FOPEN_NOFLUSH`, `max_background=128` | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-bg128-20260525-try-order` | `55.749s` | `8.626ms` | `46.457ms` | Not kept |
| `FOPEN_NOFLUSH`, `max_background=32` | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-bg32-20260525-try-order` | `54.312s` | `7.870ms` | `42.508ms` | Neutral; not kept |
| no-stats worker timing cleanup | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-notiming1-20260525` | `54.178s` | `8.068ms` | `41.110ms` | Kept |
| no-stats worker timing cleanup repeat | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-notiming2-20260525` | `54.504s` | `7.399ms` | `44.394ms` | Confirmed |
| generic reply `writev` | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-writev1-20260525` | `55.745s` | `8.301ms` | `45.575ms` | Kept |
| generic reply `writev` clean retry | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-writev4-20260525` | `53.147s` | `8.201ms` | `42.529ms` | Confirmed |
| zero-message `opendir` | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-noopendir1-20260525` | `54.514s` | `8.641ms` | `41.603ms` | Safe but neutral; removed |
| reusable HTTP/2 frame payload buffer | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-framebuf1-20260525` | `53.716s` | `7.795ms` | `44.480ms` | Kept |
| CAS read splice threshold `64KiB` | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-splice64k1-20260525` | `52.746s` | `7.225ms` | `37.619ms` | Kept as default |
| no-splice threshold | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-nosplice1-20260525` | `54.780s` | `7.947ms` | `42.279ms` | Rejected |
| RPC window-update batching, combined run 1 | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-combined1-20260525` | `53.738s` | `8.095ms` | `43.025ms` | Neutral; removed |
| RPC window-update batching, combined run 2 | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-combined2-20260525` | `54.523s` | `7.951ms` | `42.727ms` | Neutral; removed |
| final candidate, high-load run | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-finalcand1-20260525` | `63.482s` | n/a | n/a | Repeated because fork/setup/process medians were all inflated |
| final candidate confirmation | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-finalcand2-20260525` | `54.441s` | `8.615ms` | `57.251ms` | Accepted as confirmation under current host load |
| CAS read splice threshold `256KiB` | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-splice256k1-20260525` | `56.994s` | `9.441ms` | `57.480ms` | Rejected |

The `FOPEN_NOFLUSH` stats run confirmed the mechanism. Compared with the
passthrough stats diagnostic before this change, total FUSE requests dropped
from `3,090,232` to `2,537,951`, the broad `other` bucket dropped from
`1,032,901` to `487,891`, read requests dropped from `17,569` to `11,143`, and
read bytes dropped from `454,724,482` to `352,724,105`. The helper already
treated `flush` as a no-op, so `FOPEN_NOFLUSH` removes avoidable close-time
round trips and appears to preserve more useful kernel-side cached file data.
The first no-flush run measured `102.774s`, but it overlapped many stale Bazel
server processes from earlier isolated output bases; after killing those stale
servers, the two confirmation runs landed at `53.693s` and `54.231s`.

The confirmed default band is therefore about `53-56s` on this host when the
machine is not saturated by unrelated builds. The remaining visible fixed
overhead is single-digit milliseconds at p50; most elapsed time is now the
compiler/process work and the long-tail scheduling behavior of a highly
parallel local executor workload.

The no-stats worker cleanup avoids two monotonic clock reads and elapsed-time
math on every FUSE request when stats are disabled. It is wall-time neutral but
keeps the default benchmark path closer to the production no-stats hot path.
The generic reply `writev` cleanup avoids allocating and copying
`FuseOutHeader + payload` for non-scratch replies. Two earlier `writev` retries
were discarded because one was interrupted by sleep/CPU policy changes and one
was manually stopped after the run was already contaminated; the final clean
retry landed at `53.147s`.

The `64KiB` splice threshold was the clearest additional win in this pass. Once
stable file nodes moved hot CAS input reads into the kernel page cache, small
CAS reads were cheaper through the helper's existing `pread` plus scratch reply
path than through a pipe/splice round trip. Larger reads still use splice, which
keeps the useful zero-copy path without paying it for tiny reads. Fully
disabling splice and raising the threshold to `256KiB` were both slower.

The RPC-side changes kept are allocation reductions and remote-connection
hygiene: one reusable inbound HTTP/2 frame payload buffer per connection,
stack-encoded small response header blocks, and TCP_NODELAY on accepted sockets.
The window-update batching probe was removed because it did not produce a clear
win and adds avoidable flow-control state. Zero-message `opendir` was also
removed after a neutral run; the request reduction was not enough to justify
carrying another negotiated behavior.

## 2026-05-23 FUSE Passthrough Experiment

This host can negotiate Linux FUSE passthrough once
`/sys/module/fuse/parameters/allow_sys_admin_access` and
`/sys/module/fuse/parameters/enable_uring` are both set to `Y`. The helper sees
`kernel_minor=45`, replies with protocol minor `40`, and negotiates
`FUSE_PASSTHROUGH` through `flags2`.

That did not improve the LLVM FUSE smoke in the safe configuration. The helper
reported `opens=0` and all attempted passthrough opens were skipped as
executable inputs. A CAS-directory scan of the same run found many LLVM source
and header FileNodes explicitly marked executable by Bazel's remote input tree,
so the REAPI executable bit is too broad to decide which files can safely use
passthrough.

Forcing executable passthrough is not viable. A test build changed CAS backing
blob permissions from `0444` to `0555` before `FUSE_DEV_IOC_BACKING_OPEN`; the
warmup still failed during `execve` with `EIO` for
`copy_to_directory_linux_amd64/copy_to_directory`. The failed output root was
`/tmp/actiond-llvm-linux-smoke.sFvipx`. This points to Linux FUSE passthrough
not being safe for executable input files in this path, independent of plain
Unix mode bits.

The next plausible FUSE speedup would need a semantics-aware way to use
passthrough for data reads while keeping any possibly executable file on the
normal FUSE read path, or a larger design change such as a persistent helper
with cross-action caches. A filename-extension heuristic would make this smoke
faster but would be unsound for general REAPI execution because actions may
execute arbitrary input paths.

A native materialized-control run was attempted at
`/tmp/actiond-llvm-linux-smoke.stJ1aC`, but it filled `/tmp` and failed with
`NoSpaceLeft`/`WriteFailed` during warmup. A second attempt moved the output root
to `/var/mnt/dev/actiond-worker/llvm-smokes/materialized-20260524-075539`, but
that made the current materialized implementation clearly non-competitive on
this host's ext4 filesystem. After about `371s`, the warmup had only completed
`1659` remote actions, had grown the server root to about `101G`, and was still
short of the `1974` warmup action count. Parsed completed-action timings showed
`input_fetch_ns` p50 `0.944ms` but p95 `10060.970ms`; cumulative completed
`input_fetch_ns` was about `2272s` across concurrent actions.

The materialized slowdown is therefore not ordinary process execution. It comes
from eager tree materialization: `Store.materializeTreeFile` hardlinks
non-executable files, but copies executable files so it can preserve the REAPI
executable bit without mutating immutable CAS blobs. Bazel's LLVM input trees
mark many files executable, so ext4 materialized mode repeatedly copies large
tree contents. This host's `/var/mnt/dev` is ext4, and `cp --reflink=always`
fails with `Operation not supported`, so the btrfs reflink plan cannot be
validated here.

Two unsafe probes narrowed the possible fix. Hardlinking every executable-marked
tree file avoided the copy path, but failed immediately because
`copy_to_directory_linux_amd64/copy_to_directory` was actually executed from a
directory input and lost its executable bit. Avoiding directory binds only under
the action's `argv[0]` got farther, but still failed with setup `FileNotFound`;
the executable/tool closure is broader than `argv[0]`, and directory-bind
fallback needs a real design rather than a simple heuristic.

This leaves two plausible directions:

1. Keep FUSE/actiondfs and make it persistent across actions so directory and
   blob caches survive beyond one action.
2. Build a materialized/tree-cache mode only on a filesystem with cheap per-file
   clones, or with a tool-closure-aware overlay of executable copies over a
   hardlinked read-only tree.

The second direction must stay optional. On this host, `/var` and `/var/home`
are btrfs and `cp --reflink=always` works there, but the actiond checkout and
`/var/mnt/dev/actiond-worker` are mounted from an ext4 development volume.
Actiond should not rely on btrfs-specific behavior for its primary Linux path;
reflinks can be a probed optimization, not the default performance model.

A follow-up FUSE passthrough-deny experiment tried to keep inputs backed by
existing CAS files while disabling passthrough for likely executable paths. The
first LLVM warmup action failed with `EIO` opening
`libcxxabi_headers_include_search_directory_config.json` after the helper
successfully opened one passthrough backing file. That means the current
passthrough implementation is not yet safe even for a data-input open; it needs
a separate protocol/correctness fix before it can be used as the mmap/passthrough
fast path.

A 2026-05-24 protocol audit found one concrete bug in the helper's passthrough
reply: Linux passthrough opens must not include `FOPEN_KEEP_CACHE`, but the
helper was setting `FOPEN_KEEP_CACHE` before adding `FOPEN_PASSTHROUGH`. The
helper now only returns `FOPEN_KEEP_CACHE` for normal FUSE opens. This is a
correctness fix for future passthrough use, not a measured speedup by itself,
because the current LLVM input roots still skip every attempted passthrough open
as executable.

Two probes after that fix did not produce a safe passthrough path:

- Allowing executable-marked inputs to passthrough still failed immediately at
  `execve` with `EIO` for
  `external/bazel_lib++toolchains+copy_to_directory_linux_amd64/copy_to_directory`.
- Classifying only ELF and shebang blobs as actual executable content allowed a
  JSON config file to get a passthrough backing id, but the action still failed
  with `EIO` opening
  `libcxxabi_headers_include_search_directory_config.json`.

The same representative REAPI input root marked `231/231` files executable,
including musl headers that are `0644` in Bazel's external cache. The
`is_executable` bit is therefore too broad for this workload to select the small
set of files that must stay on the normal FUSE path, but Linux passthrough is
still not usable here even for a non-ELF data file.

A 2026-05-25 retry with the current persistent FUSE defaults confirmed the same
state. With stats enabled and the correctness-preserving rule that only
non-executable CAS inputs may use passthrough, the LLVM smoke completed at
`54.537s` from
`/var/mnt/dev/actiond-worker/llvm-smokes/fuse-pt-current-stats-20260525-132425`.
The helper negotiated passthrough but reported `opens=0` and
`skip_executable=468838`.

Two unsafe probes were then tried and removed:

- Classifying executable-marked files by content so non-ELF/non-shebang blobs
  could passthrough failed during warmup after opening three JSON config files
  with backing ids. The actions returned `open(...): input/output error` for
  `*_include_search_directory_config.json`.
- Adding `FOPEN_DIRECT_IO` to the passthrough open and, separately, chmodding
  executable-marked backing blobs to `0555` before `FUSE_DEV_IOC_BACKING_OPEN`
  both failed the same way.

The Linux FUSE implementation maps these policy mistakes to user-visible `EIO`
after the daemon replies to `open`. The kernel path rejects passthrough when the
requested inode I/O mode conflicts with the inode's existing cached mode or with
passthrough requirements. Without dynamic-debug access to
`fs/fuse/iomode.c`, the exact kernel errno is not visible, but the practical
result is clear: on this host/kernel/workload, passthrough cannot be used for
Bazel's executable-marked LLVM inputs while preserving correctness.

A materialized-control probe that hardlinked executable-marked data and copied
only ELF/shebang files was also not kept. It reduced some per-action
materialization timings, but the warmup failed early with setup `FileNotFound`
around directory-input binding. That points to a separate materialized
directory-input correctness issue, not a clean replacement for actiondfs.

After reverting the unsafe probes and keeping only the `FOPEN_KEEP_CACHE`
passthrough protocol fix, two full optimized FUSE LLVM smokes completed:

| output root | Bazel elapsed | input fetch p50 | process/io p50 | process/io p95 | passthrough opens |
| --- | ---: | ---: | ---: | ---: | ---: |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-ptfix-full-20260524-090523` | `113.165s` | `14.628ms` | `89.607ms` | `1420.777ms` | `0` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-ptfix-full2-20260524-090909` | `106.621s` | `14.273ms` | `81.996ms` | `1432.698ms` | `0` |

Both runs parsed `1998` execute records, all `input_mode=actiondfs_strict`,
with no `overlayfs`, `mount_overlay`, or `actiondfs_overlay` matches in the
output roots. Since passthrough opens stayed at zero, these better numbers are
not evidence that passthrough fixed the read path. They are the current best
optimized FUSE measurements under lower host contention, and they reinforce
that the remaining wall time is dominated by action `process/io` through FUSE,
not setup or input materialization.

## 2026-05-24 Persistent FUSE Prototype

A first persistent-helper prototype now exposes per-action roots from a registry
under one long-lived FUSE mount. Each action writes a registry entry containing
its input root digest and stage directory, then bind-mounts the corresponding
helper subdirectory onto `/workspace`. This removes the helper process and FUSE
mount from the per-action hot path while keeping strict actiondfs semantics and
the same per-action writable stage directory.

The first registry-mode run failed because the old per-action blob fd cache
became process-lifetime state. After enough actions, the helper started
returning `OpenFailed` and compilers saw `EIO`/missing input files. Registry
mode now closes CAS blob fds instead of caching them forever; it relies on the
kernel page cache rather than a process-lifetime userspace fd cache.

The corrected persistent run completed the full LLVM Linux FUSE smoke:

| output root | Bazel elapsed | input fetch p50 | process/io p50 | process/io p95 |
| --- | ---: | ---: | ---: | ---: |
| `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-persistent-fdclose-20260524-095336` | `99.680s` | `0.960ms` | `84.204ms` | `1338.048ms` |

This confirms the persistent mount directly attacks the per-action setup cost:
input fetch/materialization p50 dropped from about `14ms` to about `1ms`. It
did not initially solve the dominant read/runtime gap; `process/io` still owned
almost all elapsed action time because every action still exposed the same CAS
inputs through fresh FUSE inode identities.

Follow-up lifecycle experiments did not survive validation:

- compiling stats out caused early `SIGBUS` failures in the Go
  `copy_to_directory` actions;
- arming `PR_SET_PDEATHSIG` in the helper caused `MountFailed` during FUSE
  startup;
- increasing helper workers from 4 to 8 produced no useful improvement
  (`99.527s`, process/io p50 `83.107ms`);
- enabling FUSE writeback cache failed correctness with `llvm-ar` I/O errors.

The helper therefore keeps stats enabled, does not use pdeathsig, and relies on
explicit benchmark cleanup of the persistent mount/helper.

Local kernel headers and module parameters show that FUSE-over-io_uring is
available in principle on this host: `/usr/include/linux/fuse.h` defines
`FUSE_OVER_IO_URING`, `FUSE_DEV_IOC_SYNC_INIT`,
`FUSE_IO_URING_CMD_REGISTER`, and `FUSE_IO_URING_CMD_COMMIT_AND_FETCH`, and
`/sys/module/fuse/parameters/enable_uring` is `Y`. There are no liburing
headers installed, only the shared library, so a quick Zig implementation would
need direct `io_uring_setup`/`io_uring_enter`/`IORING_OP_URING_CMD` bindings.
That is larger than the persistent-mount experiment and has not been attempted
yet.

## 2026-05-24 Persistent FUSE Cache Experiments

With persistent FUSE in place, the remaining hot path was repeated read traffic
through distinct per-action FUSE nodes. A directory blob byte cache avoided
rereading directory protobuf blobs, but only gave a small improvement:

| experiment | output root | Bazel elapsed | input fetch p50 | process/io p50 | process/io p95 |
| --- | --- | ---: | ---: | ---: | ---: |
| persistent, close blob fds | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-persistent-fdclose-20260524-095336` | `99.680s` | `0.960ms` | `84.204ms` | `1338.048ms` |
| persistent, directory blob cache | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-persistent-dircache-20260524-105821` | `96.530s` | `0.962ms` | `82.222ms` | `1297.340ms` |
| persistent, directory blob cache repeat | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-persistent-dircache2-20260524-110151` | `111.573s` | `1.224ms` | `84.998ms` | `1630.331ms` |
| persistent, parsed directory template cache | `/tmp/actiond-llvm-linux-smoke.ZSLnna` | `98.646s` | `0.800ms` | `84.237ms` | `1349.114ms` |

The parsed-template cache confirmed that directory decode was not the dominant
cost. Its helper-lifetime stats still showed `4,186,541` read requests and
`310.03GB` of read replies across warmup plus measured build, despite only
`5,298` distinct directory blob reads.

The decisive change was making immutable input file nodes stable across actions
for the same `(name, digest, size, executable)` inside the persistent mount.
That gives the kernel one FUSE inode identity for repeated CAS input files, so
the FUSE page cache can be reused across actions instead of refilling for every
action root.

Two optimized LLVM Linux FUSE smokes confirmed the result:

| output root | Bazel elapsed | input fetch p50 | process/io p50 | process/io p95 | FUSE read requests | FUSE read bytes |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/tmp/actiond-llvm-linux-smoke.iv9pei` | `80.091s` | `0.771ms` | `25.732ms` | `1159.662ms` | `13,191` | `361.99MB` |
| `/tmp/actiond-llvm-linux-smoke.UDsrv1` | `80.089s` | `0.763ms` | `26.952ms` | `1164.565ms` | `12,757` | `358.44MB` |

Both runs parsed `1,998` execute records, all in `actiondfs_strict` mode, and
the checked logs had no `overlayfs`, `mount_overlay`, or `actiondfs_overlay`
matches. Passthrough was negotiated but unused (`opens=0`), so the speedup came
from persistent inode identity and kernel cache reuse rather than Linux FUSE
passthrough.

This brings the native FUSE path to the edge of the target under current host
contention. The remaining gap is no longer bulk input reads; it is dominated by
the long-tail compile/link actions and output/stage writes through FUSE.

Two follow-up probes clarified the remaining metadata/open path:

- A single helper worker was much worse than the default four workers. The run
  was stopped after several minutes because individual action `process/io`
  timings were already hundreds of milliseconds to seconds. Four workers are
  still needed to service concurrent metadata/open traffic.
- Re-enabling executable FUSE passthrough still failed immediately with
  `execve EIO` for
  `external/bazel_lib++toolchains+copy_to_directory_linux_amd64/copy_to_directory`,
  even after the passthrough protocol fix and current module parameters. The
  helper therefore still skips executable-marked CAS files for passthrough.

The final small win was making normal immutable CAS `open` lazy. In persistent
registry mode, long-lived blob fd caching is disabled to avoid fd exhaustion, so
the helper was opening and immediately closing the CAS blob on every FUSE
`open` just to validate that the blob existed. The actual read path already
opens the blob and reports missing CAS content if it is absent. Deferring that
validation removed hundreds of thousands of open/close pairs:

| output root | Bazel elapsed | input fetch p50 | process/io p50 | process/io p95 | FUSE read requests | FUSE read bytes | CAS blob opens |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `/tmp/actiond-llvm-linux-smoke.QI7G6y` | `79.995s` | `0.793ms` | `25.951ms` | `1193.991ms` | `17,484` | `369.62MB` | `17,356` |
| `/tmp/actiond-llvm-linux-smoke.uoRVrS` | `79.381s` | `0.768ms` | `25.875ms` | `1161.132ms` | `12,659` | `358.15MB` | `12,533` |

The predecessor `/tmp/actiond-llvm-linux-smoke.UDsrv1` had `480,761` CAS blob
opens for about the same read volume. The lazy-open change reduced FUSE `open`
handler time from about `5.714s` to `1.472s` in helper-lifetime counters and
confirmed the benchmark below the 80s target twice.

## Direct Bazel Linux Sandbox Comparison

For a native Bazel baseline, run the same LLVM target and warmup locally with
`--spawn_strategy=linux-sandbox`, `--genrule_strategy=linux-sandbox`, `-c opt`,
Linux x86_64 musl target/host platforms, no disk cache, and `--jobs=8`.

The first direct run used the repo's shared Bazel output base and was
contaminated by a slow `bazel clean --expunge` plus a CPU-heavy default Bazel
server in the background. Treat it as an outlier:

| output root | Bazel elapsed | critical path | processes |
| --- | ---: | ---: | --- |
| `/var/mnt/dev/actiond-worker/direct-bazel-sandbox-20260524-121615` | `83.876s` | `7.12s` | `2079 processes: 81 internal, 1998 linux-sandbox` |

Two follow-up runs used isolated `--output_base` directories and shut the Bazel
server down after completion. These are the cleaner direct sandbox comparison:

| output root | warmup wall | Bazel elapsed | critical path | processes |
| --- | ---: | ---: | ---: | --- |
| `/var/mnt/dev/actiond-worker/direct-bazel-sandbox-20260524-122215-isolated` | `47.47s` | `62.262s` | `6.46s` | `2079 processes: 81 internal, 1998 linux-sandbox` |
| `/var/mnt/dev/actiond-worker/direct-bazel-sandbox-20260524-122500-isolated` | `44.61s` | `60.779s` | `6.70s` | `2079 processes: 81 internal, 1998 linux-sandbox` |

Compared to the 2026-05-24 FUSE default run (`56.736s`) and the confirmed
manual best band (`54.246-58.050s`) for the same `1,998` remotely executed
actions, native FUSE is now in the same band as direct Bazel `linux-sandbox` on
this host and can be a few seconds faster on clean runs. Critical path is
similar, so remaining differences are mostly aggregate throughput across many
actions rather than one unusually slow long pole.

Native Bazel `linux-sandbox` still pays per-action sandbox setup, but action
inputs are ordinary kernel VFS paths from Bazel's execroot/sandbox tree. It does
not route compiler metadata/open/write traffic through a userspace FUSE daemon,
does not serialize REAPI Execute/CAS/ActionCache traffic through gRPC, and does
not collect outputs through actiond. The FUSE path has closed the bulk read gap
by reusing immutable input file inodes and kernel FUSE page cache, but it still
pays about `3.0M` FUSE requests over the full warmup plus measured smoke:
approximately `1.49M` lookups, `472k` opens, `39k` writes, and `19k` mutations.

This comparison changes the next target: after persistent FUSE, stable input
inodes, measured action-cache miss removal, and stats/thread tuning, further
wins need to reduce metadata/write round trips or remove remote-action fixed
overhead. More input read caching alone is unlikely to find another large step
function for this workload.

## 2026-05-24 Follow-up Probes

The booted host image still does not have QEMU activated in `/usr`:
`qemu-system-x86_64`, `qemu-system-x86_64-core`, and `qemu-kvm` are absent from
`PATH`, and `rpm -q qemu-system-x86-core` reports it is not installed in the
live filesystem. `/dev/kvm` is present, and `rpm-ostree status` shows
`qemu-system-x86-core` layered in the pending deployment. The staged deployment
does contain QEMU, and it can be run directly with:

```bash
qemu_deploy=/ostree/deploy/default/deploy/bcf62827e1ea8e4d5a9c322566dfb55df67378a29bcd6c9b7b8617fc8b896188.0
LD_LIBRARY_PATH="$qemu_deploy/usr/lib64:$qemu_deploy/usr/lib" \
  "$qemu_deploy/usr/bin/qemu-system-x86_64" --version
```

That reports QEMU `10.2.2`, and `darwin-actiond serve-vm` successfully starts
it with `-machine q35,accel=kvm -cpu host -smp 8`. A reboot into the pending
deployment, or a passwordless `rpm-ostree apply-live --allow-replacement`, is
still the cleaner host fix because the staged binary currently needs the staged
library path.

Two FUSE metadata probes did not produce another step-function speedup:

| experiment | output root | Bazel elapsed | input fetch p50 | process/io p50 | process/io p95 | notable helper stats |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| negative lookup reply | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-negative-20260524-131534` | `80.104s` | `0.770ms` | `25.083ms` | `1164.602ms` | no wall-time win, behavior backed out |
| lookup miss stats only | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-lookupstats-20260524-132104` | `79.998s` | `0.797ms` | `26.259ms` | `1171.872ms` | `lookup_misses=649,525`, `lookup=1,493,994/10.084s`, total helper request time `16.849s` |
| zero-message open opt-in | `/var/mnt/dev/actiond-worker/llvm-smokes/fuse-zeroopen-20260524-132953` | `79.448s` | `0.777ms` | `26.101ms` | `1150.306ms` | `open=1/0.010ms`, total requests dropped to `2,060,236` |

Negative lookup caching did not help, which suggests most misses are either
unique per action root or otherwise not repeatable within the kernel negative
entry cache. An early zero-message-open run removed the open request volume
without a wall-time win, and a later run with the current `jobs=16`/16-thread
default regressed to `91.826s` with child setup p95 at `165.807ms`; zero-open
therefore remains disabled. Remaining FUSE work should focus on lookup/path
metadata and staged output mutation/write behavior rather than ordinary input
file opens.

The Linux FUSE benchmark wrapper now also performs best-effort cleanup of the
persistent registry mount, runtime bind, and helper process. This matters for
iterative benchmarking because the persistent helper otherwise survives actiond
shutdown as a root-owned process with a live mount.

Two staged-QEMU VM LLVM smokes completed with KVM enabled. They are not faster
than current persistent FUSE on this host:

| output root | warmup wall | Bazel elapsed | input fetch p50 | process/io p50 | process/io p95 | fixed overhead p50 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `/var/mnt/dev/actiond-worker/llvm-smokes/qemu-staged-20260524-134439` | `67.036s` | `89.317s` | `0.498ms` | `21.615ms` | `1180.241ms` | `3.637ms` |
| `/var/mnt/dev/actiond-worker/llvm-smokes/qemu-staged-repeat-20260524-135527` | `65.635s` | `85.494s` | `0.489ms` | `21.802ms` | `1196.735ms` | `3.169ms` |

Both parsed `1,998` execute records and used `1,998` remote actions in the
measured build. The lower `process/io` median shows the in-guest path is still
more efficient per action once execution starts, but end-to-end elapsed loses to
the current persistent FUSE band (`54-58s`) in these runs. The likely remaining
VM cost is aggregate remote-execution/bridge/guest scheduling overhead rather
than actiondfs input materialization: input fetch is sub-millisecond and fixed
visible overhead p50 is only about `3-4ms`, but the overall build still takes
roughly `27-35s` beyond the best current FUSE runs.

## Main Rebase Alignment

Main moved actiondfs output staging onto the CAS disk and now chooses strict
staged actiondfs inputs for normal actions, falling back to overlay actiondfs
only when the action declares that it mutates inputs. The Linux QEMU path should
inherit that behavior unchanged: the guest uses `/cas/actiondfs-stage`, so
staged outputs and CAS blobs live on the same ext4 image and CAS promotion can
avoid an extra cross-filesystem copy.

The native FUSE prototype now follows the same default shape for normal actions:
the helper mounts directly at the workspace, receives the action stage path, and
serves staged creates/writes without a stock overlayfs layer. It should therefore
be compared against QEMU strict-mode actiondfs for read-only input actions. The
remaining non-parity case is explicit input mutation, which still belongs to
main's overlay compatibility semantics rather than the normal strict path.

The main timing doc should not be overwritten with the older FUSE/QEMU numbers
above. Rerun the LLVM smoke after any FUSE strict-mode or read-path change and
update `e2e/LLVM_VM_SMOKE_TIMINGS.md` only with fresh post-rebase data.

## Working Theory

The historical QEMU advantage came from the in-kernel actiondfs implementation,
not because virtualization itself is inherently cheaper than host execution.
After persistent FUSE inode reuse, current staged-QEMU measurements on this host
are slower overall than native FUSE even though QEMU still has lower median
per-action `process/io`.

The VM path has these advantages:

- VM-lifetime parsed directory and blob path caches.
- CAS blob reads forwarded through `backing_file_read_iter`.
- `splice_read` support.
- `mmap` forwarding to the real CAS backing file.
- A single long-lived guest where actiondfs and page-cache state survive across
  the warmup and measured actions.

The FUSE helper currently pays:

- FUSE kernel/userspace round trips for compiler metadata and file reads;
- no kernel backing-file `mmap` or `splice` equivalent;
- one global tree lock around lazy directory decode/cache work;
- per-action directory inode identities, even though immutable input file
  inodes are now shared across action roots;
- FUSE writes and mutations for staged outputs.

One runner bug found during the 2026-05-22 FUSE measurements: the LLVM smoke
script runs `bazel clean --expunge` after the server starts. If the FUSE helper
path points into `bazel-out`, direct Linux actiond later fails actions with
`NOT_FOUND: FileNotFound` when it tries to spawn the helper. The Linux smoke
runner now copies both the standalone server and FUSE helper into the output
root before starting the server, so the benchmarked process no longer depends
on Bazel output paths surviving the clean.

## Immediate Instrumentation

Add native FUSE counters before major optimization work:

- opcode counts: `lookup`, `getattr`, `open`, `read`, `readdir`, `release`,
  `forget`, `statx`, `readdirplus`, `lseek`, and unknown opcodes
- per-op p50/p95/max latency
- read bytes and read size histogram
- readdir bytes and entry count histogram
- response allocation count and allocated bytes
- tree lock wait/hold time
- directory blob reads and decoded directory count
- blob open attempts, open hits, and max cached fd count
- helper start/mount count

Compare these to VM `/proc/actiondfs_stats` counters: lookups, negative
lookups, cached lookups, blob path cache hits/misses, backing reads/bytes,
splice reads/bytes, mmap calls/bytes, and directory blob reads.

## Priority Experiments

1. Controlled ABAB baseline

   Run QEMU q35, QEMU q35 `aio=io_uring`, native FUSE `ReleaseFast
   -mcpu=native`, native materialized actiond, and linux-sandbox in alternating
   order. Collect `timings.md`, measured logs, Bazel elapsed/critical path,
   process counts, `uptime`, `free -h`, `vmstat 1`, CPU governor, and
   `perf stat -a -e task-clock,cycles,instructions,context-switches,cpu-migrations,page-faults`.

2. Per-action comparability

   Ensure QEMU and FUSE measured logs both parse all expected LLVM smoke execute
   records before doing per-digest comparisons. Earlier QEMU docs had fewer
   parsed timing records than remote action count, so aggregate stats are safer
   until logging is complete.

3. Join by action digest

   Compare the same action digests across native FUSE and QEMU. For each digest,
   compute deltas for input fetch, process/io, wait, and output upload. If most
   delta is in process/io, prioritize FUSE filesystem read/metadata behavior.
   If most delta is in input fetch, prioritize helper/mount startup.

4. Isolate helper/mount startup

   Run a no-op or tiny-action workload with one actiondfs mount per action and
   minimal file reads at jobs `1,2,4,8,16`. Measure input fetch p50/p95,
   parent prepare, fork, child setup, helper count, and elapsed time.

5. Read and mmap microbenchmark

   Add or use a representative action that repeatedly stats, opens, reads, and
   mmaps LLVM input files. Run it under native FUSE actiondfs, QEMU/kernel
   actiondfs, native materialized actiond, and linux-sandbox. Collect wall time,
   context switches, page faults, FUSE op stats, and VM actiondfs mmap/backing
   read counters.

6. FUSE read-path patches

   Benchmark these independently:

   - pread directly into a reusable `FuseOutHeader + payload` worker buffer
   - use `writev` or one prebuilt response buffer to avoid a second copy
   - cache serialized readdir payloads per loaded directory
   - add `FOPEN_CACHE_DIR`
   - implement and test `READDIRPLUS` or `READDIRPLUS_AUTO`

7. FUSE passthrough feasibility

   This host's `linux/fuse.h` exposes `FUSE_PASSTHROUGH` and
   `FOPEN_PASSTHROUGH`. Test whether the installed kernel and permissions allow
   opening CAS blob backing fds with `FUSE_DEV_IOC_BACKING_OPEN` and returning
   passthrough file handles. This is the closest FUSE analogue to kernel
   actiondfs backing-file IO and is the highest-upside FUSE experiment.

8. Persistent/shared helper prototype

   Prototype a long-lived helper that keeps directory digest and blob path/fd
   cache state across actions. If possible, expose roots by digest under one
   FUSE mount and point each action overlay lowerdir at a digest subdirectory.
   Measure after read/readdir fixes, since setup is currently secondary to
   process/io.

9. Jobs scaling

   Run LLVM smoke at jobs `1,2,4,8,16` for native FUSE, QEMU, and linux-sandbox.
   Collect elapsed, process/io p50/p95, wait p50/p95, context switches, and CPU
   utilization. If FUSE degrades disproportionately with jobs, focus on global
   lock contention, FUSE queue contention, and per-action helper churn.

10. Native actiond non-actiondfs control

   Run `linux-actiond serve` without `--experimental-actiondfs` using the same
   LLVM smoke flags. If it is close to linux-sandbox, FUSE/actiondfs is the main
   culprit. If it is also slow, remote actiond runner/CAS overhead is a
   meaningful part of the gap.

## Expected Decision Points

- If FUSE passthrough works and closes most of the process/io gap, continue the
  native FUSE path as the likely lightweight Linux option.
- If read/readdir fixes help only marginally and passthrough is unavailable,
  treat native FUSE as a correctness/debug path rather than a high-performance
  replacement for the VM.
- If native materialized actiond is already much slower than linux-sandbox, fix
  runner/CAS overhead before further actiondfs-specific work.
