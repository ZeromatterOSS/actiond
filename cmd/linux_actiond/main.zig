const std = @import("std");
const Io = std.Io;
const actiond = @import("actiond");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 1 and std.mem.eql(u8, args[1], "serve")) {
        const options = try actiond.host_server.parseServeArgs(args[2..]);
        return actiond.host_server.serve(io, std.heap.smp_allocator, options);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "serve-vm")) {
        const options = try actiond.vm_host.parseServeQemuVmArgs(args[2..]);
        return actiond.vm_host.serveQemu(io, std.heap.smp_allocator, options);
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        \\linux-actiond zig={s} bazel={s}
        \\usage:
        \\  linux-actiond serve [--listen=127.0.0.1:8980] [--root=/tmp/actiond] [--runtime-image=/path/runtimes.sqfs|--runtime-root=/mnt/runtimes]
        \\  linux-actiond serve-vm --cas-image=/path/cas.ext4 [--kernel=/path/bzImage[.zst]] [--initramfs=/path/initramfs.cpio[.zst]] [--runtime-image=/path/runtimes.sqfs] [--listen=127.0.0.1:8980] [--root=/tmp/actiond-vm] [--qemu=qemu-system-x86_64] [--qemu-machine=q35|microvm] [--qemu-cache=none] [--qemu-aio=io_uring] [--qemu-block-queues=N] [--guest-executor-timing-logs=0|1]
        \\
    , .{
        actiond.version.zig,
        actiond.version.bazel,
    });
    try stdout.flush();
}
