const builtin = @import("builtin");
const std = @import("std");
const control_transport_fd = @import("control_transport_fd.zig");
const vsock = @import("vsock.zig");

const linux = std.os.linux;
pub const default_drive_aio = "io_uring";

pub const Error = error{
    ConnectFailed,
    ConnectTimedOut,
    KvmUnavailable,
    MissingRuntimeImage,
    QemuUnavailable,
    StartFailed,
    UnsupportedHost,
};

pub const Options = struct {
    kernel_path: []const u8,
    initramfs_path: []const u8,
    runtime_image_path: ?[]const u8 = null,
    cas_image_path: []const u8,
    memory_mib: u64 = 512,
    cpu_count: u32 = 2,
    start_timeout_ms: u32 = 30_000,
    connect_timeout_ms: u32 = 60_000,
    connect_attempt_timeout_ms: u32 = 1_000,
    qemu_path: []const u8 = "qemu-system-x86_64",
    qemu_machine: MachineModel = .q35,
    guest_cid: u32 = 42,
    allow_tcg: bool = false,
    drive_cache: []const u8 = "none",
    drive_aio: ?[]const u8 = default_drive_aio,
    block_queue_count: ?u32 = null,
};

pub const MachineModel = enum {
    q35,
    microvm,

    pub fn parse(value: []const u8) !MachineModel {
        if (std.mem.eql(u8, value, "q35")) return .q35;
        if (std.mem.eql(u8, value, "microvm")) return .microvm;
        return error.UnsupportedQemuMachine;
    }
};

pub const Machine = struct {
    child: std.process.Child,
    guest_cid: u32,
    connect_timeout_ms: u32,
    connect_attempt_timeout_ms: u32,

    pub fn start(io: std.Io, allocator: std.mem.Allocator, options: Options) !Machine {
        if (comptime builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
            return error.UnsupportedHost;
        }
        if (!options.allow_tcg) try ensureReadableFile(io, "/dev/kvm", error.KvmUnavailable);
        if (std.mem.indexOfScalar(u8, options.qemu_path, '/') != null) {
            try ensureReadableFile(io, options.qemu_path, error.QemuUnavailable);
        }

        const runtime_image_path = options.runtime_image_path orelse return error.MissingRuntimeImage;
        const memory = try std.fmt.allocPrint(allocator, "{d}M", .{options.memory_mib});
        defer allocator.free(memory);
        const cpus = try std.fmt.allocPrint(allocator, "{d}", .{options.cpu_count});
        defer allocator.free(cpus);
        const machine_arg = qemuMachineArg(options.qemu_machine, options.allow_tcg);
        const cpu_arg = qemuCpuArg(options.qemu_machine, options.allow_tcg);
        const vsock_driver = switch (options.qemu_machine) {
            .q35 => "vhost-vsock-pci",
            .microvm => "vhost-vsock-device",
        };
        const block_driver = switch (options.qemu_machine) {
            .q35 => "virtio-blk-pci",
            .microvm => "virtio-blk-device",
        };
        const vsock_device = try std.fmt.allocPrint(allocator, "{s},id=vsock0,guest-cid={d}", .{ vsock_driver, options.guest_cid });
        defer allocator.free(vsock_device);
        const cas_block_device = try blockDeviceArg(allocator, block_driver, "cas", options.block_queue_count);
        defer allocator.free(cas_block_device);
        const runtime_block_device = try blockDeviceArg(allocator, block_driver, "runtimes", options.block_queue_count);
        defer allocator.free(runtime_block_device);
        const cas_drive = try driveArg(allocator, "cas", options.cas_image_path, false, options.drive_cache, options.drive_aio);
        defer allocator.free(cas_drive);
        const runtime_drive = try driveArg(allocator, "runtimes", runtime_image_path, true, options.drive_cache, options.drive_aio);
        defer allocator.free(runtime_drive);

        const argv = [_][]const u8{
            options.qemu_path,
            "-machine", machine_arg,
            "-cpu", cpu_arg,
            "-smp", cpus,
            "-m", memory,
            "-nodefaults",
            "-nographic",
            "-no-reboot",
            "-serial", "mon:stdio",
            "-kernel", options.kernel_path,
            "-initrd", options.initramfs_path,
            "-append", "console=ttyS0 panic=-1",
            "-device", vsock_device,
            "-drive", cas_drive,
            "-device", cas_block_device,
            "-drive", runtime_drive,
            "-device", runtime_block_device,
        };

        var child = try std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        errdefer child.kill(io);

        var machine = Machine{
            .child = child,
            .guest_cid = options.guest_cid,
            .connect_timeout_ms = options.connect_timeout_ms,
            .connect_attempt_timeout_ms = options.connect_attempt_timeout_ms,
        };
        machine.waitForControlPort(options.start_timeout_ms) catch |err| {
            machine.deinit(io);
            return err;
        };
        return machine;
    }

    pub fn deinit(self: *Machine, io: std.Io) void {
        self.child.kill(io);
        self.* = undefined;
    }

    pub fn opener(self: *Machine) control_transport_fd.Opener {
        return .{
            .ctx = self,
            .open = open,
        };
    }

    fn open(ctx: *anyopaque) !std.posix.fd_t {
        const self: *Machine = @ptrCast(@alignCast(ctx));
        return self.connectControlPort(vsock.control_port);
    }

    pub fn connectControlPort(self: *Machine, port: u32) !std.posix.fd_t {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedHost;

        var remaining_ms = if (self.connect_timeout_ms == 0)
            self.connect_attempt_timeout_ms
        else
            self.connect_timeout_ms;

        while (true) {
            if (connectVsock(self.guest_cid, port)) |fd| return fd else |err| {
                if (remaining_ms <= self.connect_attempt_timeout_ms) {
                    std.log.err("timed out connecting to guest cid={d} vsock:{d}: {s}", .{ self.guest_cid, port, @errorName(err) });
                    return error.ConnectTimedOut;
                }
            }

            const sleep_ms = @min(@as(u32, 100), remaining_ms);
            sleepMilliseconds(sleep_ms);
            remaining_ms -= sleep_ms;
        }
    }

    fn waitForControlPort(self: *Machine, timeout_ms: u32) !void {
        const original_timeout = self.connect_timeout_ms;
        self.connect_timeout_ms = timeout_ms;
        defer self.connect_timeout_ms = original_timeout;

        const fd = try self.connectControlPort(vsock.control_port);
        _ = linux.close(fd);
    }
};

fn qemuMachineArg(machine: MachineModel, allow_tcg: bool) []const u8 {
    return switch (machine) {
        .q35 => if (allow_tcg) "q35,accel=tcg" else "q35,accel=kvm",
        .microvm => if (allow_tcg) "microvm,accel=tcg,pit=on,rtc=on,pic=on" else "microvm,accel=kvm,pit=on,rtc=on,pic=on",
    };
}

fn qemuCpuArg(machine: MachineModel, allow_tcg: bool) []const u8 {
    if (allow_tcg) return "max";
    return switch (machine) {
        .q35 => "host",
        .microvm => "host,migratable=off,+invtsc",
    };
}

fn driveArg(
    allocator: std.mem.Allocator,
    id: []const u8,
    path: []const u8,
    readonly: bool,
    cache: []const u8,
    aio: ?[]const u8,
) ![]u8 {
    const readonly_arg = if (readonly) ",readonly=on" else "";
    if (aio) |aio_mode| {
        return std.fmt.allocPrint(allocator, "if=none,id={s},file={s},format=raw{s},cache={s},aio={s}", .{
            id,
            path,
            readonly_arg,
            cache,
            aio_mode,
        });
    }
    return std.fmt.allocPrint(allocator, "if=none,id={s},file={s},format=raw{s},cache={s}", .{
        id,
        path,
        readonly_arg,
        cache,
    });
}

fn blockDeviceArg(
    allocator: std.mem.Allocator,
    driver: []const u8,
    drive_id: []const u8,
    queue_count: ?u32,
) ![]u8 {
    if (queue_count) |queues| {
        return std.fmt.allocPrint(allocator, "{s},drive={s},num-queues={d}", .{ driver, drive_id, queues });
    }
    return std.fmt.allocPrint(allocator, "{s},drive={s}", .{ driver, drive_id });
}

fn connectVsock(cid: u32, port: u32) !std.posix.fd_t {
    const socket_rc = linux.socket(linux.AF.VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    switch (std.posix.errno(socket_rc)) {
        .SUCCESS => {},
        else => return error.ConnectFailed,
    }
    const fd: i32 = @intCast(socket_rc);
    errdefer _ = linux.close(fd);

    var addr = linux.sockaddr.vm{
        .family = linux.AF.VSOCK,
        .reserved1 = 0,
        .port = port,
        .cid = cid,
        .flags = 0,
        .zero = [_]u8{0} ** 3,
    };
    const connect_rc = linux.connect(
        fd,
        @as(*const linux.sockaddr, @ptrCast(&addr)),
        @sizeOf(linux.sockaddr.vm),
    );
    switch (std.posix.errno(connect_rc)) {
        .SUCCESS => return fd,
        else => return error.ConnectFailed,
    }
}

fn ensureReadableFile(io: std.Io, path: []const u8, err: anyerror) !void {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return err;
    file.close(io);
}

fn sleepMilliseconds(milliseconds: u32) void {
    var request: std.c.timespec = .{
        .sec = @intCast(milliseconds / std.time.ms_per_s),
        .nsec = @intCast((milliseconds % std.time.ms_per_s) * std.time.ns_per_ms),
    };
    while (std.c.nanosleep(&request, &request) != 0) {}
}

test "qemu VM start is Linux x86_64-only" {
    if (comptime builtin.os.tag != .linux or builtin.cpu.arch != .x86_64) {
        try std.testing.expectError(error.UnsupportedHost, Machine.start(std.testing.io, std.testing.allocator, .{
            .kernel_path = "/kernel",
            .initramfs_path = "/initramfs",
            .runtime_image_path = "/runtimes",
            .cas_image_path = "/cas.ext4",
        }));
    }
}

test "driveArg includes optional cache and aio modes" {
    const without_aio = try driveArg(std.testing.allocator, "cas", "/tmp/cas.ext4", false, "none", null);
    defer std.testing.allocator.free(without_aio);
    try std.testing.expectEqualStrings("if=none,id=cas,file=/tmp/cas.ext4,format=raw,cache=none", without_aio);

    const with_aio = try driveArg(std.testing.allocator, "runtimes", "/tmp/runtimes.sqfs", true, "none", "io_uring");
    defer std.testing.allocator.free(with_aio);
    try std.testing.expectEqualStrings("if=none,id=runtimes,file=/tmp/runtimes.sqfs,format=raw,readonly=on,cache=none,aio=io_uring", with_aio);
}

test "qemuMachineArg selects KVM or TCG accelerators" {
    try std.testing.expectEqualStrings("q35,accel=kvm", qemuMachineArg(.q35, false));
    try std.testing.expectEqualStrings("q35,accel=tcg", qemuMachineArg(.q35, true));
    try std.testing.expectEqualStrings("microvm,accel=kvm,pit=on,rtc=on,pic=on", qemuMachineArg(.microvm, false));
    try std.testing.expectEqualStrings("microvm,accel=tcg,pit=on,rtc=on,pic=on", qemuMachineArg(.microvm, true));
}

test "qemuCpuArg exposes invariant TSC for KVM microvm" {
    try std.testing.expectEqualStrings("host", qemuCpuArg(.q35, false));
    try std.testing.expectEqualStrings("host,migratable=off,+invtsc", qemuCpuArg(.microvm, false));
    try std.testing.expectEqualStrings("max", qemuCpuArg(.q35, true));
    try std.testing.expectEqualStrings("max", qemuCpuArg(.microvm, true));
}
