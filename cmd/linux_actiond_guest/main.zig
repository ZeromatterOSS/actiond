const std = @import("std");
const Io = std.Io;
const actiond = @import("actiond");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len > 0 and std.mem.eql(u8, std.fs.path.basename(args[0]), "init")) {
        const options = try parseGuestWorkerArgs(args[1..]);
        return actiond.guest_init.runWithWorkerOptions(io, .{
            .log_executor_timings = options.log_executor_timings,
        });
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--guest-init")) {
        return actiond.guest_init.run(io);
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--guest-worker")) {
        const options = try parseGuestWorkerArgs(args[2..]);
        return actiond.guest_worker.runWithOptions(io, options);
    }

    var stdout_buffer: [256]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        "linux-actiond-guest zig={s} bazel={s}\nusage: linux-actiond-guest [--guest-init|--guest-worker]\n",
        .{
            actiond.version.zig,
            actiond.version.bazel,
        },
    );
    try stdout.flush();
}

fn parseGuestWorkerArgs(args: []const []const u8) !actiond.guest_worker.Options {
    var options: actiond.guest_worker.Options = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--executor-timing-logs=0") or
            std.mem.eql(u8, arg, "--executor-timing-logs=false"))
        {
            options.log_executor_timings = false;
        } else if (std.mem.eql(u8, arg, "--executor-timing-logs=1") or
            std.mem.eql(u8, arg, "--executor-timing-logs=true"))
        {
            options.log_executor_timings = true;
        } else {
            return error.UnknownGuestWorkerArgument;
        }
    }
    return options;
}

test "parse guest worker executor timing flag" {
    try std.testing.expect(!(try parseGuestWorkerArgs(&.{"--executor-timing-logs=0"})).log_executor_timings);
    try std.testing.expect((try parseGuestWorkerArgs(&.{"--executor-timing-logs=true"})).log_executor_timings);
    try std.testing.expectError(error.UnknownGuestWorkerArgument, parseGuestWorkerArgs(&.{"--bad"}));
}
