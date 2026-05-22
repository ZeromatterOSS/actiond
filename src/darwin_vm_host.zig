const std = @import("std");
const vm_host = @import("vm_host.zig");

pub const Error = vm_host.Error;
pub const ServeVmOptions = vm_host.ServeVmOptions;
pub const parseServeVmArgs = vm_host.parseServeVmArgs;

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: ServeVmOptions,
) !void {
    return vm_host.serveDarwin(io, allocator, options);
}
