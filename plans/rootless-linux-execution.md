# Rootless Linux Execution

## Goal

Make `linux-actiond` able to execute Bazel actions from a rootless Podman /
Distrobox-style environment when the host permits unprivileged user namespaces.

The target environment is not fully privileged:

- no effective capabilities in the current namespace
- no access to `/dev/loop-control`
- no initial-namespace `CAP_SYS_ADMIN`
- nested user namespaces are available
- subordinate uid/gid mappings may be available through `newuidmap` and
  `newgidmap`

The rootless path should preserve the existing actiond model where practical:

- each action gets an isolated filesystem view
- action inputs are read-only
- actions get a private network namespace with loopback only
- runtime libraries can be provided for dynamically linked tools
- cgroup limits remain best-effort

## Current Shape

The direct Linux runner assumes it can perform privileged setup directly from
the actiond process:

1. The server optionally mounts the runtime SquashFS through `/dev/loop-control`.
2. The action parent prepares a chroot under the worker root.
3. The child calls `unshare(CLONE_NEWNS | CLONE_NEWNET)`.
4. The child makes `/` private.
5. The child applies actiondfs and read-only bind mounts.
6. The child `chroot`s into the action root.
7. The child drops to sandbox uid/gid `65534:65534`.
8. The child execs the action command.

In a rootless distrobox this fails before useful execution:

- opening `/dev/loop-control` returns `EACCES`
- `unshare(CLONE_NEWNS | CLONE_NEWNET)` returns `EPERM`
- bind mounts return `EPERM`
- `chroot` returns `EPERM`
- dropping to `65534:65534` fails unless those IDs are mapped

There is also a diagnostic bug: these binaries link libc, so
`std.posix.errno()` has libc `errno` semantics, but several call sites pass raw
`std.os.linux` syscall return values. That can misreport syscall failures as
`SUCCESS`.

## Target Model

Add an explicit rootless Linux execution mode:

```text
linux-actiond serve --rootless --runtime-root=/path/to/extracted-runtimes
```

Rootless mode should:

- never try to mount the runtime SquashFS through loop devices
- require or prepare an extracted runtime root
- create a user namespace before creating the mount and network namespaces
- perform mounts and chroot from a namespace where the child has namespaced
  `CAP_SYS_ADMIN`
- use only mapped sandbox uid/gid values
- report clear setup failures when the host does not allow required namespace
  operations

The existing privileged Linux mode should remain the default.

## Runtime Handling

Loop-backed SquashFS mounts require privileges in the initial user namespace and
are not a rootless-compatible runtime source.

Rootless mode should support one of these runtime sources:

1. User-supplied extracted runtime root:

   ```bash
   unsquashfs -f -d /tmp/actiond-runtimes bazel-bin/runtimes/runtimes-x86_64.sqfs
   linux-actiond serve --rootless --runtime-root=/tmp/actiond-runtimes
   ```

2. Later convenience path: extract the embedded `.actiond.runtimes` SquashFS to
   a content-addressed directory under the worker root.

The first implementation should prefer the explicit `--runtime-root` path so
the executor work can be validated without adding a SquashFS reader or shelling
out to `unsquashfs`.

## Namespace Setup

The rootless child setup needs a parent/child handshake instead of the current
single `fork()` path.

Proposed sequence:

1. Parent creates pipes for stdio, setup status, and namespace setup control.
2. Parent clones or forks a child that creates a user namespace plus mount and
   network namespaces.
3. Parent writes uid/gid maps for the child:
   - single-ID mode maps actiond's current user to uid/gid `0`
   - multi-ID mode uses `newuidmap` and `newgidmap` so a non-root sandbox uid is
     available inside the namespace
4. Child waits until mappings are installed.
5. Child sets `PR_SET_NO_NEW_PRIVS`.
6. Child brings up loopback.
7. Child makes mounts private.
8. Child applies actiondfs and bind mounts.
9. Child `chroot`s and `chdir`s.
10. Child drops to a mapped sandbox uid/gid if configured.
11. Child execs the command.

Using `CLONE_NEWUSER` together with `CLONE_NEWNS` and `CLONE_NEWNET` is the key
difference from the privileged runner. The new mount and network namespaces must
be owned by the newly created user namespace.

## UID/GID Modes

Rootless mode has two useful uid/gid configurations.

### Single-ID Mode

Map the current host uid/gid to namespace uid/gid `0`.

Pros:

- works without subordinate ID ranges
- enough for bind mounts, chroot, and loopback setup in environments that allow
  unprivileged user namespaces

Cons:

- cannot drop to `65534:65534`
- all action files written through host-backed directories are owned by the
  actiond user outside the namespace

This mode is a good first milestone.

### Subuid/Subgid Mode

Use `newuidmap` and `newgidmap` to map a subordinate range into the child user
namespace. Run action setup as namespace root, then drop to an in-range sandbox
uid/gid before exec.

Pros:

- closer to current privileged semantics
- supports an unprivileged action uid/gid inside the namespace

Cons:

- requires host `/etc/subuid`, `/etc/subgid`, `newuidmap`, and `newgidmap`
- needs more parent/child setup code

This mode should follow single-ID mode.

## Runner Shape

Add an execution mode to `action_runner.RunOptions`:

```zig
pub const LinuxIsolationMode = union(enum) {
    privileged,
    rootless: RootlessOptions,
};
```

Initial `RootlessOptions`:

```zig
pub const RootlessOptions = struct {
    uid_mode: RootlessUidMode = .single,
};
```

`forkAction` should split into mode-specific helpers:

- privileged: current flow, after syscall error handling is fixed
- rootless: user-namespace flow with mapping handshake

Keep the child mount, chroot, stdio, timing, and output collection behavior
shared where possible.

## Syscall Error Handling

Before changing namespace behavior, fix raw syscall errno handling.

Add a local helper for `std.os.linux` syscall return values:

```zig
fn linuxErrno(rc: usize) std.os.linux.E {
    return std.os.linux.errno(rc);
}
```

Use it for every direct `std.os.linux.*` syscall return. Continue using
`std.posix` wrappers where the code wants libc-backed POSIX behavior.

This should make rootless failures report `PERM`, `ACCES`, or `NOENT` at the
first failing operation instead of later printing `execve SUCCESS`.

## Serve Flags

Add Linux serve flags:

```text
--rootless
--rootless-uid-mode=single|subid
```

Validation:

- `--rootless` with `--runtime-image` fails clearly for the first version
- `--rootless` with no runtime source should either fail clearly or require an
  explicit future `--extract-runtime-image` flag
- `--rootless-uid-mode=subid` should check for `newuidmap` and `newgidmap`
  before accepting actions

## Tests

Unit tests:

- parse rootless serve flags
- reject `--rootless --runtime-image`
- accept `--rootless --runtime-root`
- rootless uid mode parsing
- Linux syscall errno helper maps negative raw returns correctly
- runner selects privileged mode by default
- runner selects rootless mode when requested

Local probe tests, gated to Linux hosts that allow unprivileged user namespaces:

- rootless child can create mount and network namespaces
- rootless child can bind mount an input directory read-only
- rootless child can chroot into the action root
- rootless child can bring up loopback
- single-ID mode runs a simple static action

E2E:

- add `ACTIOND_E2E_ROOTLESS=1 tools/e2e.sh linux`
- rootless e2e should use extracted runtime root, not `--runtime-image`
- if user namespaces are unavailable, skip with a clear message
- do not claim normal Linux e2e coverage from rootless e2e; it is a separate
  execution mode

## Implementation Notes

- Single-ID mode runs action setup and the action command as namespace uid/gid
  `0`, mapped to actiond's current host uid/gid. This is the only rootless uid
  mode accepted by this branch.
- Rootless mode requires an extracted runtime root. The e2e harness extracts
  the built SquashFS runtime with `unsquashfs` before starting `linux-actiond`.
- Rootless mode fails closed for network isolation. The child still creates a
  private network namespace and brings up loopback only.
- Some Bazel actions and generated scripts refer to host-style absolute tools
  such as `/usr/bin/bash`. Rootless mode binds a small, architecture-specific
  set of host tool and loader/library files into the chroot so these actions can
  run in environments where binding `/usr/bin` or `/lib` directories from the
  container overlay filesystem is rejected.
