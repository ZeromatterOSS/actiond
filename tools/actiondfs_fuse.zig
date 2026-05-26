const std = @import("std");
const actiond = @import("actiond");

const cas = actiond.cas;
const protobuf = actiond.protobuf_wire;
const reapi = actiond.reapi;

const empty_sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
const default_threads = 16;
const read_buffer_len = 1024 * 1024 + 8192;
const splice_pipe_size = 1024 * 1024;
const default_splice_min_bytes = 64 * 1024;
var enable_fuse_stats = false;
var splice_min_bytes: usize = default_splice_min_bytes;
const fopen_keep_cache = 1 << 1;
const fopen_cache_dir = 1 << 3;
const fopen_noflush = 1 << 5;
const fopen_passthrough = 1 << 7;
const fuse_async_read = 1 << 0;
const fuse_big_writes = 1 << 5;
const fuse_no_open_support = 1 << 17;
const fuse_parallel_dirops = 1 << 18;
const fuse_max_pages = 1 << 22;
const fuse_init_ext = 1 << 30;
const fuse_passthrough: u64 = 1 << 37;
const fuse_passthrough_flags2: u32 = @intCast(fuse_passthrough >> 32);
const fuse_max_backing_stack_depth = 8;
const fuse_dev_ioc_magic = 229;
const fuse_dev_ioc_backing_open = ioctlIow(fuse_dev_ioc_magic, 1, @sizeOf(FuseBackingMap));
const fuse_dev_ioc_backing_close = ioctlIow(fuse_dev_ioc_magic, 2, @sizeOf(u32));
const f_setpipe_sz = 1031;
const f_getpipe_sz = 1032;
const splice_f_more = 4;
const fattr_mode = 1 << 0;
const fattr_uid = 1 << 1;
const fattr_gid = 1 << 2;
const fattr_size = 1 << 3;

const FuseOpcode = enum(u32) {
    lookup = 1,
    forget = 2,
    getattr = 3,
    setattr = 4,
    readlink = 5,
    mknod = 8,
    mkdir = 9,
    unlink = 10,
    rmdir = 11,
    rename = 12,
    open = 14,
    read = 15,
    write = 16,
    statfs = 17,
    release = 18,
    flush = 25,
    init = 26,
    opendir = 27,
    readdir = 28,
    releasedir = 29,
    fsyncdir = 30,
    access = 34,
    create = 35,
    destroy = 38,
    batch_forget = 42,
    readdirplus = 44,
    lseek = 46,
    copy_file_range = 47,
    statx = 52,
    copy_file_range_64 = 53,
    _,
};

const FuseInHeader = extern struct {
    len: u32,
    opcode: u32,
    unique: u64,
    nodeid: u64,
    uid: u32,
    gid: u32,
    pid: u32,
    padding: u32,
};

const FuseOutHeader = extern struct {
    len: u32,
    err: i32,
    unique: u64,
};

const FuseAttr = extern struct {
    ino: u64,
    size: u64,
    blocks: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    nlink: u32,
    uid: u32,
    gid: u32,
    rdev: u32,
    blksize: u32,
    flags: u32,
};

const FuseEntryOut = extern struct {
    nodeid: u64,
    generation: u64,
    entry_valid: u64,
    attr_valid: u64,
    entry_valid_nsec: u32,
    attr_valid_nsec: u32,
    attr: FuseAttr,
};

const FuseAttrOut = extern struct {
    attr_valid: u64,
    attr_valid_nsec: u32,
    dummy: u32,
    attr: FuseAttr,
};

const FuseOpenIn = extern struct {
    flags: u32,
    open_flags: u32,
};

const FuseOpenOut = extern struct {
    fh: u64,
    open_flags: u32,
    backing_id: i32,
};

const FuseReleaseIn = extern struct {
    fh: u64,
    flags: u32,
    release_flags: u32,
    lock_owner: u64,
};

const FuseBackingMap = extern struct {
    fd: i32,
    flags: u32 = 0,
    padding: u64 = 0,
};

const FuseReadIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    read_flags: u32,
    lock_owner: u64,
    flags: u32,
    padding: u32,
};

const FuseWriteIn = extern struct {
    fh: u64,
    offset: u64,
    size: u32,
    write_flags: u32,
    lock_owner: u64,
    flags: u32,
    padding: u32,
};

const FuseWriteOut = extern struct {
    size: u32,
    padding: u32 = 0,
};

const FuseCopyFileRangeIn = extern struct {
    fh_in: u64,
    off_in: u64,
    nodeid_out: u64,
    fh_out: u64,
    off_out: u64,
    len: u64,
    flags: u64,
};

const FuseCopyFileRangeOut = extern struct {
    bytes_copied: u64,
};

const FuseSetattrIn = extern struct {
    valid: u32,
    padding: u32,
    fh: u64,
    size: u64,
    lock_owner: u64,
    atime: u64,
    mtime: u64,
    ctime: u64,
    atimensec: u32,
    mtimensec: u32,
    ctimensec: u32,
    mode: u32,
    unused4: u32,
    uid: u32,
    gid: u32,
    unused5: u32,
};

const FuseMknodIn = extern struct {
    mode: u32,
    rdev: u32,
    umask: u32,
    padding: u32,
};

const FuseMkdirIn = extern struct {
    mode: u32,
    umask: u32,
};

const FuseRenameIn = extern struct {
    newdir: u64,
};

const FuseCreateIn = extern struct {
    flags: u32,
    mode: u32,
    umask: u32,
    padding: u32,
};

const FuseInitIn = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
    flags2: u32,
    unused: [11]u32,
};

const ParsedFuseInit = struct {
    major: u32 = 7,
    minor: u32 = 40,
    max_readahead: u32 = 128 * 1024,
    flags: u32 = 0,
    flags2: u32 = 0,
};

const FuseInitOut = extern struct {
    major: u32,
    minor: u32,
    max_readahead: u32,
    flags: u32,
    max_background: u16,
    congestion_threshold: u16,
    max_write: u32,
    time_gran: u32,
    max_pages: u16,
    map_alignment: u16,
    flags2: u32,
    max_stack_depth: u32,
    request_timeout: u16,
    unused: [11]u16,
};

const FuseKstatfs = extern struct {
    blocks: u64,
    bfree: u64,
    bavail: u64,
    files: u64,
    ffree: u64,
    bsize: u32,
    namelen: u32,
    frsize: u32,
    padding: u32,
    spare: [6]u32,
};

const FuseStatfsOut = extern struct {
    st: FuseKstatfs,
};

const FuseDirent = extern struct {
    ino: u64,
    off: u64,
    namelen: u32,
    type: u32,
};

const Stats = struct {
    requests: std.atomic.Value(u64) = .init(0),
    errors: std.atomic.Value(u64) = .init(0),
    request_ns: std.atomic.Value(u64) = .init(0),
    lookup_ops: std.atomic.Value(u64) = .init(0),
    lookup_ns: std.atomic.Value(u64) = .init(0),
    lookup_misses: std.atomic.Value(u64) = .init(0),
    getattr_ops: std.atomic.Value(u64) = .init(0),
    getattr_ns: std.atomic.Value(u64) = .init(0),
    open_ops: std.atomic.Value(u64) = .init(0),
    open_ns: std.atomic.Value(u64) = .init(0),
    read_ops: std.atomic.Value(u64) = .init(0),
    read_ns: std.atomic.Value(u64) = .init(0),
    readdir_ops: std.atomic.Value(u64) = .init(0),
    readdir_ns: std.atomic.Value(u64) = .init(0),
    write_ops: std.atomic.Value(u64) = .init(0),
    write_ns: std.atomic.Value(u64) = .init(0),
    mutation_ops: std.atomic.Value(u64) = .init(0),
    mutation_ns: std.atomic.Value(u64) = .init(0),
    other_ops: std.atomic.Value(u64) = .init(0),
    other_ns: std.atomic.Value(u64) = .init(0),
    reply_ops: std.atomic.Value(u64) = .init(0),
    reply_bytes: std.atomic.Value(u64) = .init(0),
    read_bytes: std.atomic.Value(u64) = .init(0),
    readdir_bytes: std.atomic.Value(u64) = .init(0),
    dir_loads: std.atomic.Value(u64) = .init(0),
    decoded_dirs: std.atomic.Value(u64) = .init(0),
    decoded_files: std.atomic.Value(u64) = .init(0),
    blob_opens: std.atomic.Value(u64) = .init(0),
    init_body_len: std.atomic.Value(u64) = .init(0),
    init_kernel_minor: std.atomic.Value(u64) = .init(0),
    init_reply_minor: std.atomic.Value(u64) = .init(0),
    init_kernel_flags: std.atomic.Value(u64) = .init(0),
    init_kernel_flags2: std.atomic.Value(u64) = .init(0),
    init_passthrough_supported: std.atomic.Value(u64) = .init(0),
    passthrough_opens: std.atomic.Value(u64) = .init(0),
    passthrough_open_failures: std.atomic.Value(u64) = .init(0),
    passthrough_closes: std.atomic.Value(u64) = .init(0),
    passthrough_close_failures: std.atomic.Value(u64) = .init(0),
    passthrough_skip_disabled: std.atomic.Value(u64) = .init(0),
    passthrough_skip_staged: std.atomic.Value(u64) = .init(0),
    passthrough_skip_non_file: std.atomic.Value(u64) = .init(0),
    passthrough_skip_executable: std.atomic.Value(u64) = .init(0),
    passthrough_skip_empty: std.atomic.Value(u64) = .init(0),
    splice_read_ops: std.atomic.Value(u64) = .init(0),
    splice_read_bytes: std.atomic.Value(u64) = .init(0),
    splice_fallbacks: std.atomic.Value(u64) = .init(0),
    splice_failures: std.atomic.Value(u64) = .init(0),
    copy_file_range_ops: std.atomic.Value(u64) = .init(0),
    copy_file_range_bytes: std.atomic.Value(u64) = .init(0),
    copy_file_range_fallbacks: std.atomic.Value(u64) = .init(0),
    copy_file_range_failures: std.atomic.Value(u64) = .init(0),
    directory_blob_reads: std.atomic.Value(u64) = .init(0),
    directory_blob_bytes: std.atomic.Value(u64) = .init(0),
    stage_getdents: std.atomic.Value(u64) = .init(0),
    stage_stats: std.atomic.Value(u64) = .init(0),

    fn add(counter: *std.atomic.Value(u64), amount: u64) void {
        if (!enable_fuse_stats) return;
        _ = counter.fetchAdd(amount, .monotonic);
    }

    fn set(counter: *std.atomic.Value(u64), amount: u64) void {
        if (!enable_fuse_stats) return;
        counter.store(amount, .monotonic);
    }

    fn value(counter: *const std.atomic.Value(u64)) u64 {
        return counter.load(.monotonic);
    }

    fn recordRequest(self: *Stats, opcode_raw: u32, ns: u64, failed: bool) void {
        if (!enable_fuse_stats) return;
        Stats.add(&self.requests, 1);
        Stats.add(&self.request_ns, ns);
        if (failed) Stats.add(&self.errors, 1);

        const opcode: FuseOpcode = @enumFromInt(opcode_raw);
        switch (opcode) {
            .lookup => self.recordPair(&self.lookup_ops, &self.lookup_ns, ns),
            .getattr, .statx => self.recordPair(&self.getattr_ops, &self.getattr_ns, ns),
            .open, .opendir => self.recordPair(&self.open_ops, &self.open_ns, ns),
            .read => self.recordPair(&self.read_ops, &self.read_ns, ns),
            .readdir, .readdirplus => self.recordPair(&self.readdir_ops, &self.readdir_ns, ns),
            .write => self.recordPair(&self.write_ops, &self.write_ns, ns),
            .copy_file_range, .copy_file_range_64 => self.recordPair(&self.write_ops, &self.write_ns, ns),
            .setattr, .mknod, .mkdir, .unlink, .rmdir, .rename, .create => self.recordPair(&self.mutation_ops, &self.mutation_ns, ns),
            else => self.recordPair(&self.other_ops, &self.other_ns, ns),
        }
    }

    fn recordPair(self: *Stats, ops: *std.atomic.Value(u64), ns_counter: *std.atomic.Value(u64), ns: u64) void {
        _ = self;
        Stats.add(ops, 1);
        Stats.add(ns_counter, ns);
    }

    fn recordReply(self: *Stats, bytes: usize) void {
        if (!enable_fuse_stats) return;
        Stats.add(&self.reply_ops, 1);
        Stats.add(&self.reply_bytes, @intCast(bytes));
    }

    fn print(self: *const Stats) void {
        if (!enable_fuse_stats) return;
        const requests = value(&self.requests);
        if (requests == 0) return;
        std.debug.print(
            "actiondfs_fuse stats: requests={d} errors={d} request_ns={d} lookup={d}/{d} getattr={d}/{d} open={d}/{d} read={d}/{d} read_bytes={d} readdir={d}/{d} readdir_bytes={d} write={d}/{d} mutation={d}/{d} other={d}/{d} replies={d} reply_bytes={d} dir_loads={d} decoded_dirs={d} decoded_files={d} blob_opens={d} directory_blob_reads={d} directory_blob_bytes={d} stage_getdents={d} stage_stats={d}\n",
            .{
                requests,
                value(&self.errors),
                value(&self.request_ns),
                value(&self.lookup_ops),
                value(&self.lookup_ns),
                value(&self.getattr_ops),
                value(&self.getattr_ns),
                value(&self.open_ops),
                value(&self.open_ns),
                value(&self.read_ops),
                value(&self.read_ns),
                value(&self.read_bytes),
                value(&self.readdir_ops),
                value(&self.readdir_ns),
                value(&self.readdir_bytes),
                value(&self.write_ops),
                value(&self.write_ns),
                value(&self.mutation_ops),
                value(&self.mutation_ns),
                value(&self.other_ops),
                value(&self.other_ns),
                value(&self.reply_ops),
                value(&self.reply_bytes),
                value(&self.dir_loads),
                value(&self.decoded_dirs),
                value(&self.decoded_files),
                value(&self.blob_opens),
                value(&self.directory_blob_reads),
                value(&self.directory_blob_bytes),
                value(&self.stage_getdents),
                value(&self.stage_stats),
            },
        );
        std.debug.print(
            "actiondfs_fuse lookup_cache: lookup_misses={d}\n",
            .{
                value(&self.lookup_misses),
            },
        );
        std.debug.print(
            "actiondfs_fuse passthrough: init_body={d} kernel_minor={d} reply_minor={d} kernel_flags=0x{x} kernel_flags2=0x{x} negotiated={d} opens={d} open_failures={d} closes={d} close_failures={d} skip_disabled={d} skip_staged={d} skip_non_file={d} skip_executable={d} skip_empty={d}\n",
            .{
                value(&self.init_body_len),
                value(&self.init_kernel_minor),
                value(&self.init_reply_minor),
                value(&self.init_kernel_flags),
                value(&self.init_kernel_flags2),
                value(&self.init_passthrough_supported),
                value(&self.passthrough_opens),
                value(&self.passthrough_open_failures),
                value(&self.passthrough_closes),
                value(&self.passthrough_close_failures),
                value(&self.passthrough_skip_disabled),
                value(&self.passthrough_skip_staged),
                value(&self.passthrough_skip_non_file),
                value(&self.passthrough_skip_executable),
                value(&self.passthrough_skip_empty),
            },
        );
        std.debug.print(
            "actiondfs_fuse read_path: splice_reads={d} splice_read_bytes={d} splice_fallbacks={d} splice_failures={d}\n",
            .{
                value(&self.splice_read_ops),
                value(&self.splice_read_bytes),
                value(&self.splice_fallbacks),
                value(&self.splice_failures),
            },
        );
        std.debug.print(
            "actiondfs_fuse copy_file_range: ops={d} bytes={d} fallbacks={d} failures={d}\n",
            .{
                value(&self.copy_file_range_ops),
                value(&self.copy_file_range_bytes),
                value(&self.copy_file_range_fallbacks),
                value(&self.copy_file_range_failures),
            },
        );
    }
};

const SplicePipe = struct {
    read_fd: std.posix.fd_t,
    write_fd: std.posix.fd_t,
    capacity: usize,

    fn init() !SplicePipe {
        var fds: [2]std.posix.fd_t = undefined;
        switch (std.os.linux.errno(std.os.linux.pipe2(&fds, .{ .CLOEXEC = true }))) {
            .SUCCESS => {},
            else => return error.PipeFailed,
        }
        errdefer closeFd(fds[0]);
        errdefer closeFd(fds[1]);
        _ = fcntlInt(fds[0], f_setpipe_sz, splice_pipe_size) catch {};
        const capacity = fcntlInt(fds[0], f_getpipe_sz, 0) catch 64 * 1024;
        return .{
            .read_fd = fds[0],
            .write_fd = fds[1],
            .capacity = @intCast(capacity),
        };
    }

    fn deinit(self: *SplicePipe) void {
        closeFd(self.read_fd);
        closeFd(self.write_fd);
    }

    fn discard(self: *SplicePipe, scratch: []u8, count: usize) void {
        var remaining = count;
        while (remaining > 0) {
            const n = readFd(self.read_fd, scratch[0..@min(scratch.len, remaining)]) catch return;
            if (n == 0) return;
            remaining -= n;
        }
    }
};

const Mutex = struct {
    state: std.atomic.Mutex = .unlocked,

    fn lock(self: *Mutex) void {
        while (!self.state.tryLock()) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *Mutex) void {
        self.state.unlock();
    }
};

const NodeKind = enum { directory, file };

const CachedDirectoryEntry = struct {
    name: []const u8,
    hash: []const u8,
    size: u64 = 0,
    executable: bool = false,

    fn deinit(self: CachedDirectoryEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.hash);
    }
};

const CachedDirectory = struct {
    directories: []const CachedDirectoryEntry = &.{},
    files: []const CachedDirectoryEntry = &.{},

    fn deinit(self: *CachedDirectory, allocator: std.mem.Allocator) void {
        for (self.directories) |entry| entry.deinit(allocator);
        allocator.free(self.directories);
        for (self.files) |entry| entry.deinit(allocator);
        allocator.free(self.files);
        self.* = .{};
    }
};

const empty_cached_directory: CachedDirectory = .{};

fn buildCachedDirectory(allocator: std.mem.Allocator, decoded: reapi.Directory) !CachedDirectory {
    var directories = try allocator.alloc(CachedDirectoryEntry, decoded.directories.len);
    var directory_count: usize = 0;
    errdefer {
        for (directories[0..directory_count]) |entry| entry.deinit(allocator);
        allocator.free(directories);
    }

    for (decoded.directories) |child| {
        const digest = try cas.Digest.fromReapi(child.digest orelse return error.MissingDirectoryDigest);
        directories[directory_count] = try cachedDirectoryEntry(allocator, child.name, digest, 0, false);
        directory_count += 1;
    }

    var files = try allocator.alloc(CachedDirectoryEntry, decoded.files.len);
    var file_count: usize = 0;
    errdefer {
        for (files[0..file_count]) |entry| entry.deinit(allocator);
        allocator.free(files);
    }

    for (decoded.files) |child| {
        const digest = try cas.Digest.fromReapi(child.digest orelse return error.MissingFileDigest);
        files[file_count] = try cachedDirectoryEntry(allocator, child.name, digest, digest.size_bytes, child.is_executable);
        file_count += 1;
    }

    return .{
        .directories = directories,
        .files = files,
    };
}

fn cachedDirectoryEntry(
    allocator: std.mem.Allocator,
    name: []const u8,
    digest: cas.Digest,
    size: u64,
    executable: bool,
) !CachedDirectoryEntry {
    const name_copy = try allocator.dupe(u8, name);
    errdefer allocator.free(name_copy);

    var hash_buffer: [64]u8 = undefined;
    const hash = digest.formatHex(&hash_buffer);
    const hash_copy = try allocator.dupe(u8, hash);

    return .{
        .name = name_copy,
        .hash = hash_copy,
        .size = size,
        .executable = executable,
    };
}

fn fileNodeCacheKey(
    allocator: std.mem.Allocator,
    name: []const u8,
    hash: []const u8,
    size: u64,
    executable: bool,
) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}\x00{d}\x00{d}\x00{s}", .{ hash, size, @intFromBool(executable), name });
}

const Node = struct {
    id: u64,
    parent_id: u64,
    name: []u8,
    path: []u8,
    stage_root: []u8,
    kind: NodeKind,
    hash: []u8,
    size: u64,
    executable: bool = false,
    staged: bool = false,
    registry_root: bool = false,
    children_loaded: bool = false,
    children: std.StringHashMapUnmanaged(*Node) = .empty,
    child_order: std.ArrayListUnmanaged(*Node) = .empty,
    blob_fd: std.atomic.Value(i32) = .init(-1),
    backing_id: ?i32 = null,
    blob_lock: Mutex = .{},

    fn deinit(self: *Node, allocator: std.mem.Allocator) void {
        const fd = self.blob_fd.load(.acquire);
        if (fd >= 0) closeFd(@intCast(fd));
        self.children.deinit(allocator);
        self.child_order.deinit(allocator);
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.stage_root);
        allocator.free(self.hash);
        allocator.destroy(self);
    }
};

const open_handle_tag: u64 = 1;

const OpenHandle = struct {
    node: *Node,
    fd: std.posix.fd_t,
};

const Options = struct {
    root_hash: ?[]const u8 = null,
    cas_root: []const u8,
    stage_root: ?[]const u8 = null,
    registry_root: ?[]const u8 = null,
    mountpoint: []const u8,
    threads: usize = default_threads,
};

const Server = struct {
    allocator: std.mem.Allocator,
    fuse_fd: std.posix.fd_t,
    cas_root: []const u8,
    registry_root: ?[]const u8 = null,
    nodes: std.AutoHashMapUnmanaged(u64, *Node) = .empty,
    tree_lock: Mutex = .{},
    next_node_id: u64 = 2,
    passthrough_enabled: bool = false,
    zero_message_open: bool = false,
    zero_message_open_supported: bool = false,
    negative_lookup_cache: bool = false,
    cache_blob_fds: bool = true,
    directory_cache: std.StringHashMapUnmanaged(CachedDirectory) = .empty,
    file_node_cache: std.StringHashMapUnmanaged(*Node) = .empty,
    stats: Stats = .{},

    fn init(
        allocator: std.mem.Allocator,
        fuse_fd: std.posix.fd_t,
        cas_root: []const u8,
        stage_root: []const u8,
        root_hash: []const u8,
        zero_message_open: bool,
        negative_lookup_cache: bool,
    ) !Server {
        var server = Server{
            .allocator = allocator,
            .fuse_fd = fuse_fd,
            .cas_root = try allocator.dupe(u8, cas_root),
            .zero_message_open = zero_message_open,
            .negative_lookup_cache = negative_lookup_cache,
        };
        errdefer server.deinit();

        const root = try allocator.create(Node);
        root.* = .{
            .id = 1,
            .parent_id = 1,
            .name = try allocator.dupe(u8, ""),
            .path = try allocator.dupe(u8, ""),
            .stage_root = try allocator.dupe(u8, stage_root),
            .kind = .directory,
            .hash = try allocator.dupe(u8, root_hash),
            .size = 0,
            .staged = true,
        };
        try server.nodes.put(allocator, root.id, root);
        return server;
    }

    fn initRegistry(
        allocator: std.mem.Allocator,
        fuse_fd: std.posix.fd_t,
        cas_root: []const u8,
        registry_root: []const u8,
        zero_message_open: bool,
        negative_lookup_cache: bool,
    ) !Server {
        var server = Server{
            .allocator = allocator,
            .fuse_fd = fuse_fd,
            .cas_root = try allocator.dupe(u8, cas_root),
            .registry_root = try allocator.dupe(u8, registry_root),
            .zero_message_open = zero_message_open,
            .negative_lookup_cache = negative_lookup_cache,
            .cache_blob_fds = false,
        };
        errdefer server.deinit();

        const root = try allocator.create(Node);
        root.* = .{
            .id = 1,
            .parent_id = 1,
            .name = try allocator.dupe(u8, ""),
            .path = try allocator.dupe(u8, ""),
            .stage_root = try allocator.dupe(u8, ""),
            .kind = .directory,
            .hash = try allocator.dupe(u8, ""),
            .size = 0,
            .staged = false,
            .registry_root = true,
        };
        try server.nodes.put(allocator, root.id, root);
        return server;
    }

    fn deinit(self: *Server) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node_ptr| {
            if (node_ptr.*.backing_id) |backing_id| self.closeBacking(backing_id);
            node_ptr.*.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        var directory_it = self.directory_cache.iterator();
        while (directory_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.directory_cache.deinit(self.allocator);
        var file_it = self.file_node_cache.keyIterator();
        while (file_it.next()) |key| self.allocator.free(key.*);
        self.file_node_cache.deinit(self.allocator);
        self.allocator.free(self.cas_root);
        if (self.registry_root) |path| self.allocator.free(path);
    }

    fn run(self: *Server, thread_count: usize) !void {
        const count = @max(thread_count, 1);
        const threads = try self.allocator.alloc(std.Thread, count);
        defer self.allocator.free(threads);
        for (threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerThread, .{self});
        }
        for (threads) |thread| thread.join();
    }

    fn workerThread(self: *Server) void {
        var buffer: [read_buffer_len]u8 align(8) = undefined;
        var splice_pipe = SplicePipe.init() catch null;
        defer if (splice_pipe) |*pipe| pipe.deinit();
        while (true) {
            const n = readFd(self.fuse_fd, &buffer) catch |err| switch (err) {
                error.DeviceGone => return,
                else => {
                    std.debug.print("actiondfs_fuse: read failed: {s}\n", .{@errorName(err)});
                    return;
                },
            };
            if (n < @sizeOf(FuseInHeader)) continue;
            const header = bytesAs(FuseInHeader, buffer[0..n]).*;
            const pipe_ptr: ?*SplicePipe = if (splice_pipe) |*pipe| pipe else null;
            if (enable_fuse_stats) {
                const start_ns = monotonicNowNs();
                if (self.handle(buffer[0..n], &buffer, pipe_ptr)) |_| {
                    self.stats.recordRequest(header.opcode, elapsedNs(start_ns), false);
                } else |err| {
                    self.stats.recordRequest(header.opcode, elapsedNs(start_ns), true);
                    self.replyHandleError(&header, err);
                }
            } else {
                self.handle(buffer[0..n], &buffer, pipe_ptr) catch |err| self.replyHandleError(&header, err);
            }
        }
    }

    fn replyHandleError(self: *Server, header: *const FuseInHeader, err: anyerror) void {
        const errno: std.posix.E = switch (err) {
            error.InvalidName => .INVAL,
            error.ReadOnlyFileSystem => .ROFS,
            error.FileNotFound => .NOENT,
            error.NotDir => .NOTDIR,
            else => errno: {
                std.debug.print("actiondfs_fuse: request failed opcode={d}: {s}\n", .{ header.opcode, @errorName(err) });
                break :errno .IO;
            },
        };
        self.replyErrno(header, errno) catch {};
    }

    fn handle(self: *Server, request: []u8, scratch: []u8, splice_pipe: ?*SplicePipe) !void {
        const header = bytesAs(FuseInHeader, request);
        const body = request[@sizeOf(FuseInHeader)..];
        const opcode: FuseOpcode = @enumFromInt(header.opcode);
        switch (opcode) {
            .init => try self.handleInit(header, body),
            .lookup => try self.handleLookup(header, body),
            .getattr => try self.handleGetattr(header),
            .setattr => try self.handleSetattr(header, body),
            .mknod => try self.handleMknod(header, body),
            .mkdir => try self.handleMkdir(header, body),
            .unlink => try self.handleUnlink(header, body, false),
            .rmdir => try self.handleUnlink(header, body, true),
            .rename => try self.handleRename(header, body),
            .statx => try self.replyErrno(header, std.posix.E.NOSYS),
            .opendir, .open => try self.handleOpen(header, body),
            .readdir => try self.handleReaddir(header, body, scratch),
            .readdirplus => try self.replyErrno(header, std.posix.E.NOSYS),
            .read => try self.handleRead(header, body, scratch, splice_pipe),
            .write => try self.handleWrite(header, body),
            .copy_file_range => try self.handleCopyFileRange(header, body, scratch, false),
            .copy_file_range_64 => try self.handleCopyFileRange(header, body, scratch, true),
            .release => try self.handleRelease(header, body),
            .releasedir, .flush, .fsyncdir, .access => try self.replyEmpty(header),
            .create => try self.handleCreate(header, body),
            .lseek => try self.replyErrno(header, std.posix.E.NOSYS),
            .statfs => try self.handleStatfs(header),
            .forget, .batch_forget => {},
            .destroy => {
                try self.replyEmpty(header);
                return;
            },
            else => try self.replyErrno(header, std.posix.E.NOSYS),
        }
    }

    fn handleInit(self: *Server, header: *const FuseInHeader, body: []const u8) !void {
        var parsed_init: ParsedFuseInit = .{};
        if (body.len >= 4) parsed_init.major = std.mem.readInt(u32, body[0..4], .little);
        if (body.len >= 8) parsed_init.minor = std.mem.readInt(u32, body[4..8], .little);
        if (body.len >= 12) parsed_init.max_readahead = std.mem.readInt(u32, body[8..12], .little);
        if (body.len >= 16) parsed_init.flags = std.mem.readInt(u32, body[12..16], .little);
        if (body.len >= 20) parsed_init.flags2 = std.mem.readInt(u32, body[16..20], .little);

        const minor = @min(parsed_init.minor, 40);
        const max_readahead = @max(parsed_init.max_readahead, 1024 * 1024);
        const kernel_flags = parsed_init.flags;
        const kernel_flags2 = parsed_init.flags2;
        const use_ext_flags = (kernel_flags & fuse_init_ext) != 0;
        self.passthrough_enabled = use_ext_flags and (kernel_flags2 & fuse_passthrough_flags2) != 0;
        self.zero_message_open_supported = self.zero_message_open and (kernel_flags & fuse_no_open_support) != 0;
        Stats.set(&self.stats.init_body_len, body.len);
        Stats.set(&self.stats.init_kernel_minor, parsed_init.minor);
        Stats.set(&self.stats.init_reply_minor, minor);
        Stats.set(&self.stats.init_kernel_flags, kernel_flags);
        Stats.set(&self.stats.init_kernel_flags2, kernel_flags2);
        Stats.set(&self.stats.init_passthrough_supported, @intFromBool(self.passthrough_enabled));
        var flags: u64 = fuse_async_read | fuse_big_writes | fuse_parallel_dirops | fuse_max_pages;
        if (self.zero_message_open_supported) flags |= fuse_no_open_support;
        if (use_ext_flags) {
            flags |= fuse_init_ext;
            if (self.passthrough_enabled) flags |= fuse_passthrough;
        }
        const out = FuseInitOut{
            .major = 7,
            .minor = minor,
            .max_readahead = max_readahead,
            .flags = @truncate(flags),
            .max_background = 64,
            .congestion_threshold = 48,
            .max_write = 1024 * 1024,
            .time_gran = 1,
            .max_pages = 256,
            .map_alignment = 0,
            .flags2 = if (use_ext_flags) @truncate(flags >> 32) else 0,
            .max_stack_depth = if (self.passthrough_enabled) fuse_max_backing_stack_depth + 1 else 0,
            .request_timeout = 0,
            .unused = [_]u16{0} ** 11,
        };
        try self.replyStruct(header, out);
    }

    fn handleLookup(self: *Server, header: *const FuseInHeader, body: []const u8) !void {
        const name = std.mem.trimEnd(u8, body, "\x00");
        if (std.mem.eql(u8, name, ".")) {
            const node_value = self.node(header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
            return self.replyEntry(header, node_value);
        }
        if (std.mem.eql(u8, name, "..")) {
            const node_value = self.node(header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
            const parent = self.node(node_value.parent_id) orelse return self.replyErrno(header, std.posix.E.NOENT);
            return self.replyEntry(header, parent);
        }
        const child = self.lookup(header.nodeid, name) catch |err| switch (err) {
            error.FileNotFound => {
                Stats.add(&self.stats.lookup_misses, 1);
                if (self.negative_lookup_cache) return self.replyNegativeEntry(header);
                return self.replyErrno(header, std.posix.E.NOENT);
            },
            error.InvalidName => return self.replyErrno(header, std.posix.E.INVAL),
            else => return err,
        };
        try self.replyEntry(header, child);
    }

    fn handleGetattr(self: *Server, header: *const FuseInHeader) !void {
        const node_value = self.node(header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        const out = FuseAttrOut{
            .attr_valid = 60,
            .attr_valid_nsec = 0,
            .dummy = 0,
            .attr = try self.attrFor(node_value),
        };
        try self.replyStruct(header, out);
    }

    fn handleOpen(self: *Server, header: *const FuseInHeader, body: []const u8) !void {
        if (self.zero_message_open_supported and header.opcode == @intFromEnum(FuseOpcode.open)) {
            return self.replyErrno(header, std.posix.E.NOSYS);
        }
        const node_value = self.node(header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        var flags: std.os.linux.O = .{ .ACCMODE = .RDONLY };
        if (body.len >= @sizeOf(FuseOpenIn)) {
            const open_in = bytesAsConst(FuseOpenIn, body).?;
            flags = @bitCast(open_in.flags);
        }
        if (node_value.kind == .file) {
            if (flags.ACCMODE != .RDONLY and !node_value.staged) return self.replyErrno(header, std.posix.E.ROFS);
        }
        var open_flags: u32 = 0;
        var backing_id: i32 = 0;
        var fh = nodeHandle(node_value);
        if (node_value.kind == .file) {
            if (node_value.staged) {
                const path = try self.stagePath(node_value, node_value.path);
                defer self.allocator.free(path);
                const fd = if (flags.ACCMODE == .RDONLY)
                    try openReadOnly(path)
                else
                    try openReadWrite(path);
                errdefer closeFd(fd);
                if (flags.TRUNC) {
                    try truncateFd(fd, 0);
                    node_value.size = 0;
                }
                fh = try self.createOpenHandle(node_value, fd);
                open_flags |= fopen_keep_cache | fopen_noflush;
            } else if (self.openPassthroughBacking(node_value)) |id| {
                open_flags |= fopen_passthrough;
                backing_id = id;
            } else {
                open_flags |= fopen_keep_cache | fopen_noflush;
            }
        } else {
            open_flags |= fopen_cache_dir;
        }
        const out = FuseOpenOut{
            .fh = fh,
            .open_flags = open_flags,
            .backing_id = backing_id,
        };
        try self.replyStruct(header, out);
    }

    fn handleRead(self: *Server, header: *const FuseInHeader, body: []const u8, scratch: []u8, splice_pipe: ?*SplicePipe) !void {
        if (body.len < @sizeOf(FuseReadIn)) return self.replyErrno(header, std.posix.E.INVAL);
        const read_in = bytesAsConst(FuseReadIn, body).?.*;
        const node_value = self.nodeFromFuseHandle(read_in.fh, header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (node_value.kind != .file) return self.replyErrno(header, std.posix.E.ISDIR);
        if (read_in.offset >= node_value.size) return self.replyBytes(header, "");

        const max_len = @min(@as(u64, read_in.size), node_value.size - read_in.offset);
        const len = std.math.cast(usize, max_len) orelse return self.replyErrno(header, std.posix.E.FBIG);
        if (len == 0 or (node_value.size == 0 and std.mem.eql(u8, node_value.hash, empty_sha256))) {
            return self.replyBytes(header, "");
        }
        if (len > scratch.len - @sizeOf(FuseOutHeader)) return self.replyErrno(header, std.posix.E.IO);

        var close_after_read = false;
        const fd = if (node_value.staged) fd: {
            if (openHandleFromValue(read_in.fh)) |open_handle| break :fd open_handle.fd;
            const path = try self.stagePath(node_value, node_value.path);
            defer self.allocator.free(path);
            close_after_read = true;
            break :fd openReadOnly(path) catch |err| switch (err) {
                error.FileNotFound => return self.replyErrno(header, std.posix.E.NOENT),
                else => return err,
            };
        } else self.openBlob(node_value) catch |err| switch (err) {
            error.FileNotFound => return self.replyErrno(header, std.posix.E.NOENT),
            else => return err,
        };
        defer if ((node_value.staged and close_after_read) or (!node_value.staged and !self.cache_blob_fds)) closeFd(fd);
        if (!node_value.staged and len >= splice_min_bytes) {
            if (self.replyReadSplice(header, fd, read_in.offset, len, scratch, splice_pipe)) |_| {
                return;
            } else |err| switch (err) {
                error.SpliceUnavailable => Stats.add(&self.stats.splice_fallbacks, 1),
                else => {
                    Stats.add(&self.stats.splice_failures, 1);
                    return self.replyErrno(header, std.posix.E.IO);
                },
            }
        }
        const unique = header.unique;
        const payload = scratch[@sizeOf(FuseOutHeader)..][0..len];
        const n = preadFd(fd, payload, read_in.offset) catch return self.replyErrno(header, std.posix.E.IO);
        Stats.add(&self.stats.read_bytes, @intCast(n));
        try self.replyScratchPayload(unique, scratch, n);
    }

    fn replyReadSplice(
        self: *Server,
        header: *const FuseInHeader,
        fd: std.posix.fd_t,
        offset: u64,
        len: usize,
        scratch: []u8,
        maybe_pipe: ?*SplicePipe,
    ) !void {
        const pipe = maybe_pipe orelse return error.SpliceUnavailable;
        const total_len = @sizeOf(FuseOutHeader) + len;
        if (total_len > pipe.capacity) return error.SpliceUnavailable;

        const out = FuseOutHeader{
            .len = @intCast(total_len),
            .err = 0,
            .unique = header.unique,
        };
        try writeFdAll(pipe.write_fd, std.mem.asBytes(&out));
        var staged: usize = @sizeOf(FuseOutHeader);
        var file_offset: i64 = @intCast(offset);
        var remaining = len;
        while (remaining > 0) {
            const n = spliceFd(fd, &file_offset, pipe.write_fd, null, remaining, splice_f_more) catch |err| {
                pipe.discard(scratch, staged);
                return err;
            };
            if (n == 0) {
                pipe.discard(scratch, staged);
                return error.ReadFailed;
            }
            staged += n;
            remaining -= n;
        }

        var pipe_remaining = total_len;
        while (pipe_remaining > 0) {
            const n = spliceFd(pipe.read_fd, null, self.fuse_fd, null, pipe_remaining, 0) catch |err| {
                pipe.discard(scratch, pipe_remaining);
                return err;
            };
            if (n == 0) {
                pipe.discard(scratch, pipe_remaining);
                return error.WriteFailed;
            }
            pipe_remaining -= n;
        }
        self.stats.recordReply(total_len);
        Stats.add(&self.stats.read_bytes, @intCast(len));
        Stats.add(&self.stats.splice_read_ops, 1);
        Stats.add(&self.stats.splice_read_bytes, @intCast(len));
    }

    fn handleReaddir(self: *Server, header: *const FuseInHeader, body: []const u8, scratch: []u8) !void {
        if (body.len < @sizeOf(FuseReadIn)) return self.replyErrno(header, std.posix.E.INVAL);
        const read_in = bytesAsConst(FuseReadIn, body).?.*;
        const node_value = self.nodeFromFuseHandle(read_in.fh, header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (node_value.kind != .directory) return self.replyErrno(header, std.posix.E.NOTDIR);
        try self.ensureChildren(node_value);

        const payload = scratch[@sizeOf(FuseOutHeader)..];
        const max_size = @min(std.math.cast(usize, read_in.size) orelse payload.len, payload.len);
        const unique = header.unique;
        var index: u64 = read_in.offset;
        var out_len: usize = 0;
        while (true) : (index += 1) {
            const maybe = direntAt(node_value, index) orelse break;
            if (!appendDirentBounded(payload[0..max_size], &out_len, maybe.node.id, index + 1, maybe.kind, maybe.name)) break;
        }
        Stats.add(&self.stats.readdir_bytes, @intCast(out_len));
        try self.replyScratchPayload(unique, scratch, out_len);
    }

    fn handleWrite(self: *Server, header: *const FuseInHeader, body: []const u8) !void {
        if (body.len < @sizeOf(FuseWriteIn)) return self.replyErrno(header, std.posix.E.INVAL);
        const write_in = bytesAsConst(FuseWriteIn, body).?;
        const data_start = @sizeOf(FuseWriteIn);
        const data_end = data_start + @as(usize, @intCast(write_in.size));
        if (data_end > body.len) return self.replyErrno(header, std.posix.E.INVAL);
        const node_value = self.nodeFromFuseHandle(write_in.fh, header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (node_value.kind != .file) return self.replyErrno(header, std.posix.E.ISDIR);
        if (!node_value.staged) return self.replyErrno(header, std.posix.E.ROFS);
        var close_after_write = false;
        const fd = if (openHandleFromValue(write_in.fh)) |open_handle| open_handle.fd else fd: {
            const path = try self.stagePath(node_value, node_value.path);
            defer self.allocator.free(path);
            close_after_write = true;
            break :fd try openWriteOnly(path);
        };
        defer if (close_after_write) closeFd(fd);
        try pwriteFdAll(fd, body[data_start..data_end], write_in.offset);
        node_value.size = @max(node_value.size, write_in.offset + write_in.size);
        try self.replyStruct(header, FuseWriteOut{ .size = write_in.size });
    }

    fn handleRelease(self: *Server, header: *const FuseInHeader, body: []const u8) !void {
        if (body.len >= @sizeOf(FuseReleaseIn)) {
            const release = bytesAsConst(FuseReleaseIn, body).?.*;
            if (openHandleFromValue(release.fh)) |open_handle| {
                self.destroyOpenHandle(open_handle);
            }
        }
        try self.replyEmpty(header);
    }

    fn handleCopyFileRange(
        self: *Server,
        header: *const FuseInHeader,
        body: []const u8,
        scratch: []u8,
        wide_reply: bool,
    ) !void {
        if (body.len < @sizeOf(FuseCopyFileRangeIn)) return self.replyErrno(header, std.posix.E.INVAL);
        const input = bytesAsConst(FuseCopyFileRangeIn, body).?.*;
        if (input.flags != 0) return self.replyErrno(header, std.posix.E.INVAL);

        const source = self.nodeFromFuseHandle(input.fh_in, header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        const dest = self.nodeFromFuseHandle(input.fh_out, input.nodeid_out) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (source.kind != .file or dest.kind != .file) return self.replyErrno(header, std.posix.E.ISDIR);
        if (!dest.staged) return self.replyErrno(header, std.posix.E.ROFS);

        if (input.len == 0) {
            return self.replyCopyFileRange(header, 0, wide_reply);
        }

        var close_source = false;
        const source_fd = if (source.staged) fd: {
            if (openHandleFromValue(input.fh_in)) |open_handle| break :fd open_handle.fd;
            const path = try self.stagePath(source, source.path);
            defer self.allocator.free(path);
            close_source = true;
            break :fd openReadOnly(path) catch |err| switch (err) {
                error.FileNotFound => return self.replyErrno(header, std.posix.E.NOENT),
                else => return err,
            };
        } else self.openBlob(source) catch |err| switch (err) {
            error.FileNotFound => return self.replyErrno(header, std.posix.E.NOENT),
            else => return err,
        };
        defer if ((source.staged and close_source) or (!source.staged and !self.cache_blob_fds)) closeFd(source_fd);

        var close_dest = false;
        const dest_fd = if (openHandleFromValue(input.fh_out)) |open_handle| open_handle.fd else fd: {
            const dest_path = try self.stagePath(dest, dest.path);
            defer self.allocator.free(dest_path);
            close_dest = true;
            break :fd openWriteOnly(dest_path) catch |err| switch (err) {
                error.FileNotFound => return self.replyErrno(header, std.posix.E.NOENT),
                else => return err,
            };
        };
        defer if (close_dest) closeFd(dest_fd);

        const copied = copyFileRangeFd(source_fd, input.off_in, dest_fd, input.off_out, input.len) catch |err| switch (err) {
            error.CopyFileRangeUnavailable => fallback: {
                Stats.add(&self.stats.copy_file_range_fallbacks, 1);
                break :fallback copyFdRangeManual(source_fd, input.off_in, dest_fd, input.off_out, input.len, scratch) catch {
                    Stats.add(&self.stats.copy_file_range_failures, 1);
                    return self.replyErrno(header, std.posix.E.IO);
                };
            },
            else => {
                Stats.add(&self.stats.copy_file_range_failures, 1);
                return self.replyErrno(header, std.posix.E.IO);
            },
        };

        dest.size = @max(dest.size, input.off_out + copied);
        Stats.add(&self.stats.copy_file_range_ops, 1);
        Stats.add(&self.stats.copy_file_range_bytes, copied);
        try self.replyCopyFileRange(header, copied, wide_reply);
    }

    fn replyCopyFileRange(self: *Server, header: *const FuseInHeader, copied: u64, wide_reply: bool) !void {
        if (wide_reply) {
            return self.replyStruct(header, FuseCopyFileRangeOut{ .bytes_copied = copied });
        }
        const size = std.math.cast(u32, copied) orelse return self.replyErrno(header, std.posix.E.IO);
        return self.replyStruct(header, FuseWriteOut{ .size = size });
    }

    fn handleSetattr(self: *Server, header: *const FuseInHeader, body: []const u8) !void {
        if (body.len < @sizeOf(FuseSetattrIn)) return self.replyErrno(header, std.posix.E.INVAL);
        const setattr = bytesAsConst(FuseSetattrIn, body).?;
        const node_value = self.node(header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (!node_value.staged and (setattr.valid & (fattr_mode | fattr_uid | fattr_gid | fattr_size)) != 0) {
            return self.replyErrno(header, std.posix.E.ROFS);
        }
        if (node_value.staged) {
            const path = try self.stagePath(node_value, node_value.path);
            defer self.allocator.free(path);
            if ((setattr.valid & fattr_size) != 0) {
                try truncatePath(path, setattr.size);
                node_value.size = setattr.size;
            }
            if ((setattr.valid & fattr_mode) != 0) chmodPath(path, @intCast(setattr.mode & 0o7777));
            if ((setattr.valid & (fattr_uid | fattr_gid)) != 0) chownPath(path, setattr.uid, setattr.gid);
        }
        const out = FuseAttrOut{
            .attr_valid = 60,
            .attr_valid_nsec = 0,
            .dummy = 0,
            .attr = try self.attrFor(node_value),
        };
        try self.replyStruct(header, out);
    }

    fn handleMknod(self: *Server, header: *const FuseInHeader, body: []const u8) !void {
        if (body.len < @sizeOf(FuseMknodIn)) return self.replyErrno(header, std.posix.E.INVAL);
        const input = bytesAsConst(FuseMknodIn, body).?;
        const name = std.mem.trimEnd(u8, body[@sizeOf(FuseMknodIn)..], "\x00");
        const parent = self.node(header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (parent.kind != .directory) return self.replyErrno(header, std.posix.E.NOTDIR);
        try self.ensureChildren(parent);
        if (parent.children.get(name)) |existing| {
            if (!existing.staged) return self.replyErrno(header, std.posix.E.ROFS);
            return self.replyErrno(header, std.posix.E.EXIST);
        }
        const node_value = try self.createStageFileNode(header, parent, name, input.mode, 0, null);
        try self.replyEntry(header, node_value);
    }

    fn handleMkdir(self: *Server, header: *const FuseInHeader, body: []const u8) !void {
        if (body.len < @sizeOf(FuseMkdirIn)) return self.replyErrno(header, std.posix.E.INVAL);
        const input = bytesAsConst(FuseMkdirIn, body).?;
        const name = std.mem.trimEnd(u8, body[@sizeOf(FuseMkdirIn)..], "\x00");
        const parent = self.node(header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (parent.kind != .directory) return self.replyErrno(header, std.posix.E.NOTDIR);
        try self.ensureChildren(parent);
        if (parent.children.get(name)) |existing| {
            if (!existing.staged) return self.replyErrno(header, std.posix.E.ROFS);
            return self.replyErrno(header, std.posix.E.EXIST);
        }
        const child_path = try joinPath(self.allocator, parent.path, name);
        defer self.allocator.free(child_path);
        const stage_path = try self.stagePath(parent, child_path);
        defer self.allocator.free(stage_path);
        try self.ensureStageParent(stage_path);
        try mkdirPath(stage_path, @intCast(input.mode & 0o7777));
        chownPath(stage_path, header.uid, header.gid);
        chmodPath(stage_path, @intCast(input.mode & 0o7777));

        self.tree_lock.lock();
        defer self.tree_lock.unlock();
        const node_value = try self.createNode(parent, name, .directory, child_path, "", 0, false, true);
        try self.putChild(parent, node_value);
        try self.replyEntry(header, node_value);
    }

    fn handleCreate(self: *Server, header: *const FuseInHeader, body: []const u8) !void {
        if (body.len < @sizeOf(FuseCreateIn)) return self.replyErrno(header, std.posix.E.INVAL);
        const input = bytesAsConst(FuseCreateIn, body).?;
        const name = std.mem.trimEnd(u8, body[@sizeOf(FuseCreateIn)..], "\x00");
        const parent = self.node(header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (parent.kind != .directory) return self.replyErrno(header, std.posix.E.NOTDIR);
        try self.ensureChildren(parent);
        if (parent.children.get(name)) |existing| {
            if (!existing.staged) return self.replyErrno(header, std.posix.E.ROFS);
        }
        var fd: std.posix.fd_t = -1;
        const node_value = try self.createStageFileNode(header, parent, name, input.mode, input.flags, &fd);
        errdefer if (fd >= 0) closeFd(fd);
        const entry = FuseEntryOut{
            .nodeid = node_value.id,
            .generation = 1,
            .entry_valid = 60,
            .attr_valid = 60,
            .entry_valid_nsec = 0,
            .attr_valid_nsec = 0,
            .attr = try self.attrFor(node_value),
        };
        const open = FuseOpenOut{
            .fh = try self.createOpenHandle(node_value, fd),
            .open_flags = fopen_keep_cache | fopen_noflush,
            .backing_id = 0,
        };
        fd = -1;
        var bytes = try self.allocator.alloc(u8, @sizeOf(FuseEntryOut) + @sizeOf(FuseOpenOut));
        defer self.allocator.free(bytes);
        @memcpy(bytes[0..@sizeOf(FuseEntryOut)], std.mem.asBytes(&entry));
        @memcpy(bytes[@sizeOf(FuseEntryOut)..], std.mem.asBytes(&open));
        try self.replyBytes(header, bytes);
    }

    fn handleUnlink(self: *Server, header: *const FuseInHeader, body: []const u8, directory: bool) !void {
        const name = std.mem.trimEnd(u8, body, "\x00");
        try validateName(name);
        const parent = self.node(header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (parent.kind != .directory) return self.replyErrno(header, std.posix.E.NOTDIR);
        try self.ensureChildren(parent);
        const child = parent.children.get(name) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (!child.staged) return self.replyErrno(header, std.posix.E.ROFS);
        if (directory and child.kind != .directory) return self.replyErrno(header, std.posix.E.NOTDIR);
        if (!directory and child.kind != .file) return self.replyErrno(header, std.posix.E.ISDIR);
        const path = try self.stagePath(child, child.path);
        defer self.allocator.free(path);
        if (directory) {
            try rmdirPath(path);
        } else {
            try unlinkPath(path);
        }
        self.tree_lock.lock();
        defer self.tree_lock.unlock();
        self.removeChild(parent, child);
        try self.replyEmpty(header);
    }

    fn handleRename(self: *Server, header: *const FuseInHeader, body: []const u8) !void {
        if (body.len < @sizeOf(FuseRenameIn)) return self.replyErrno(header, std.posix.E.INVAL);
        const input = bytesAsConst(FuseRenameIn, body).?;
        var names = std.mem.splitScalar(u8, body[@sizeOf(FuseRenameIn)..], 0);
        const old_name = names.next() orelse return self.replyErrno(header, std.posix.E.INVAL);
        const new_name = names.next() orelse return self.replyErrno(header, std.posix.E.INVAL);
        try validateName(old_name);
        try validateName(new_name);
        const old_parent = self.node(header.nodeid) orelse return self.replyErrno(header, std.posix.E.NOENT);
        const new_parent = self.node(input.newdir) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (old_parent.kind != .directory or new_parent.kind != .directory) return self.replyErrno(header, std.posix.E.NOTDIR);
        try self.ensureChildren(old_parent);
        try self.ensureChildren(new_parent);
        const old_child = old_parent.children.get(old_name) orelse return self.replyErrno(header, std.posix.E.NOENT);
        if (!old_child.staged) return self.replyErrno(header, std.posix.E.ROFS);
        if (new_parent.children.get(new_name)) |existing| {
            if (!existing.staged) return self.replyErrno(header, std.posix.E.ROFS);
        }
        const old_path = try self.stagePath(old_child, old_child.path);
        defer self.allocator.free(old_path);
        const new_rel_path = try joinPath(self.allocator, new_parent.path, new_name);
        defer self.allocator.free(new_rel_path);
        const new_path = try self.stagePath(new_parent, new_rel_path);
        defer self.allocator.free(new_path);
        try self.ensureStageParent(new_path);
        try renamePath(old_path, new_path);

        self.tree_lock.lock();
        defer self.tree_lock.unlock();
        self.removeChild(old_parent, old_child);
        if (new_parent.children.get(new_name)) |existing| self.removeChild(new_parent, existing);
        try self.replyEmpty(header);
    }

    fn handleStatfs(self: *Server, header: *const FuseInHeader) !void {
        const out = FuseStatfsOut{ .st = .{
            .blocks = 0,
            .bfree = 0,
            .bavail = 0,
            .files = 0,
            .ffree = 0,
            .bsize = 4096,
            .namelen = 255,
            .frsize = 4096,
            .padding = 0,
            .spare = [_]u32{0} ** 6,
        } };
        try self.replyStruct(header, out);
    }

    fn replyEntry(self: *Server, header: *const FuseInHeader, node_value: *Node) !void {
        const out = FuseEntryOut{
            .nodeid = node_value.id,
            .generation = 1,
            .entry_valid = 60,
            .attr_valid = 60,
            .entry_valid_nsec = 0,
            .attr_valid_nsec = 0,
            .attr = try self.attrFor(node_value),
        };
        try self.replyStruct(header, out);
    }

    fn replyNegativeEntry(self: *Server, header: *const FuseInHeader) !void {
        const out = FuseEntryOut{
            .nodeid = 0,
            .generation = 0,
            .entry_valid = 60,
            .attr_valid = 0,
            .entry_valid_nsec = 0,
            .attr_valid_nsec = 0,
            .attr = std.mem.zeroes(FuseAttr),
        };
        try self.replyStruct(header, out);
    }

    fn replyEmpty(self: *Server, header: *const FuseInHeader) !void {
        try self.replyBytes(header, "");
    }

    fn replyErrno(self: *Server, header: *const FuseInHeader, errno: std.posix.E) !void {
        const out = FuseOutHeader{
            .len = @sizeOf(FuseOutHeader),
            .err = -@as(i32, @intCast(@intFromEnum(errno))),
            .unique = header.unique,
        };
        self.stats.recordReply(@sizeOf(FuseOutHeader));
        try writeFdAll(self.fuse_fd, std.mem.asBytes(&out));
    }

    fn replyStruct(self: *Server, header: *const FuseInHeader, value: anytype) !void {
        const payload = std.mem.asBytes(&value);
        try self.replyBytes(header, payload);
    }

    fn replyBytes(self: *Server, header: *const FuseInHeader, payload: []const u8) !void {
        const len = @sizeOf(FuseOutHeader) + payload.len;
        const out = FuseOutHeader{
            .len = @intCast(len),
            .err = 0,
            .unique = header.unique,
        };
        self.stats.recordReply(len);
        try writevFdAll(self.fuse_fd, std.mem.asBytes(&out), payload);
    }

    fn replyScratchPayload(self: *Server, unique: u64, scratch: []u8, payload_len: usize) !void {
        const len = @sizeOf(FuseOutHeader) + payload_len;
        if (len > scratch.len) return error.WriteFailed;
        const out = FuseOutHeader{
            .len = @intCast(len),
            .err = 0,
            .unique = unique,
        };
        @memcpy(scratch[0..@sizeOf(FuseOutHeader)], std.mem.asBytes(&out));
        self.stats.recordReply(len);
        try writeFdAll(self.fuse_fd, scratch[0..len]);
    }

    fn node(self: *Server, id: u64) ?*Node {
        self.tree_lock.lock();
        defer self.tree_lock.unlock();
        return self.nodes.get(id);
    }

    fn nodeFromFuseHandle(self: *Server, fh: u64, node_id: u64) ?*Node {
        if (openHandleFromValue(fh)) |open_handle| return open_handle.node;
        if (fh != 0) return @ptrFromInt(fh);
        return self.node(node_id);
    }

    fn createOpenHandle(self: *Server, node_value: *Node, fd: std.posix.fd_t) !u64 {
        const open_handle = try self.allocator.create(OpenHandle);
        open_handle.* = .{
            .node = node_value,
            .fd = fd,
        };
        return openHandleValue(open_handle);
    }

    fn destroyOpenHandle(self: *Server, open_handle: *OpenHandle) void {
        closeFd(open_handle.fd);
        self.allocator.destroy(open_handle);
    }

    fn lookup(self: *Server, parent_id: u64, name: []const u8) !*Node {
        try validateName(name);
        self.tree_lock.lock();
        defer self.tree_lock.unlock();
        const parent = self.nodes.get(parent_id) orelse return error.FileNotFound;
        if (parent.kind != .directory) return error.FileNotFound;
        if (parent.registry_root) return try self.lookupRegistryRootLocked(parent, name);
        try self.ensureChildrenLocked(parent);
        return parent.children.get(name) orelse error.FileNotFound;
    }

    fn ensureChildren(self: *Server, directory: *Node) !void {
        self.tree_lock.lock();
        defer self.tree_lock.unlock();
        try self.ensureChildrenLocked(directory);
    }

    fn ensureChildrenLocked(self: *Server, directory: *Node) !void {
        if (directory.children_loaded) return;
        if (directory.registry_root) return;
        Stats.add(&self.stats.dir_loads, 1);

        try self.loadStageChildren(directory);

        if (directory.hash.len != 0) {
            const cached = try self.cachedDirectory(directory.hash);

            for (cached.directories) |child| {
                if (directory.children.get(child.name)) |existing| {
                    if (existing.kind == .directory and existing.hash.len == 0) {
                        self.allocator.free(existing.hash);
                        existing.hash = try self.allocator.dupe(u8, child.hash);
                    }
                    continue;
                }
                const child_path = try joinPath(self.allocator, directory.path, child.name);
                defer self.allocator.free(child_path);
                const node_value = try self.createNode(directory, child.name, .directory, child_path, child.hash, 0, false, false);
                try self.putChild(directory, node_value);
            }
            for (cached.files) |child| {
                if (directory.children.contains(child.name)) continue;
                const child_path = try joinPath(self.allocator, directory.path, child.name);
                defer self.allocator.free(child_path);
                const node_value = try self.cachedInputFileNode(directory, child.name, child_path, child.hash, child.size, child.executable);
                try self.putChild(directory, node_value);
            }
            Stats.add(&self.stats.decoded_dirs, @intCast(cached.directories.len));
            Stats.add(&self.stats.decoded_files, @intCast(cached.files.len));
        }
        directory.children_loaded = true;
    }

    fn lookupRegistryRootLocked(self: *Server, parent: *Node, name: []const u8) !*Node {
        if (parent.children.get(name)) |existing| return existing;
        const entry = try self.readRegistryEntry(name);
        defer entry.deinit(self.allocator);

        const value = try self.allocator.create(Node);
        errdefer self.allocator.destroy(value);
        const id = self.next_node_id;
        self.next_node_id += 1;
        value.* = .{
            .id = id,
            .parent_id = parent.id,
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, ""),
            .stage_root = try self.allocator.dupe(u8, entry.stage_root),
            .kind = .directory,
            .hash = try self.allocator.dupe(u8, entry.root_hash),
            .size = 0,
            .staged = true,
        };
        try self.nodes.put(self.allocator, id, value);
        try self.putChild(parent, value);
        return value;
    }

    const RegistryEntry = struct {
        root_hash: []u8,
        stage_root: []u8,

        fn deinit(self: *const RegistryEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.root_hash);
            allocator.free(self.stage_root);
        }
    };

    fn readRegistryEntry(self: *Server, name: []const u8) !RegistryEntry {
        const registry = self.registry_root orelse return error.FileNotFound;
        const path = try std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ registry, name }, 0);
        defer self.allocator.free(path);
        const fd = openReadOnly(path) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return err,
        };
        defer closeFd(fd);
        const bytes = try readFdAlloc(self.allocator, fd, 4096);
        defer self.allocator.free(bytes);

        var root_hash: ?[]const u8 = null;
        var stage_root: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "root=")) {
                root_hash = line["root=".len..];
            } else if (std.mem.startsWith(u8, line, "stage=")) {
                stage_root = line["stage=".len..];
            }
        }
        const root = root_hash orelse return error.InvalidName;
        const stage = stage_root orelse return error.InvalidName;
        if (root.len != 64 or stage.len == 0 or stage[0] != '/') return error.InvalidName;
        return .{
            .root_hash = try self.allocator.dupe(u8, root),
            .stage_root = try self.allocator.dupe(u8, stage),
        };
    }

    fn loadStageChildren(self: *Server, directory: *Node) !void {
        const path = try self.stagePath(directory, directory.path);
        defer self.allocator.free(path);
        const fd = openDirectory(path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer closeFd(fd);

        var buffer: [16 * 1024]u8 align(8) = undefined;
        while (true) {
            const n = try getdents64(fd, &buffer);
            if (n == 0) break;
            Stats.add(&self.stats.stage_getdents, 1);
            var offset: usize = 0;
            while (offset < n) {
                const entry: *align(1) const LinuxDirent64 = @ptrCast(buffer[offset..].ptr);
                if (entry.reclen == 0) return error.InvalidDirent;
                const name_start = offset + linux_dirent64_name_offset;
                const name_raw = std.mem.sliceTo(buffer[name_start..offset + entry.reclen], 0);
                offset += entry.reclen;
                if (std.mem.eql(u8, name_raw, ".") or std.mem.eql(u8, name_raw, "..")) continue;
                if (directory.children.contains(name_raw)) continue;

                const child_path = try joinPath(self.allocator, directory.path, name_raw);
                defer self.allocator.free(child_path);
                const stat = (try self.stageStat(directory, child_path)) orelse continue;
                const node_value = try self.createNode(
                    directory,
                    name_raw,
                    stat.kind,
                    child_path,
                    "",
                    stat.size,
                    stat.executable,
                    true,
                );
                try self.putChild(directory, node_value);
            }
        }
    }

    fn createNode(
        self: *Server,
        parent: *Node,
        name: []const u8,
        kind: NodeKind,
        path: []const u8,
        hash: []const u8,
        size: u64,
        executable: bool,
        staged: bool,
    ) !*Node {
        const value = try self.allocator.create(Node);
        errdefer self.allocator.destroy(value);
        const id = self.next_node_id;
        self.next_node_id += 1;
        value.* = .{
            .id = id,
            .parent_id = parent.id,
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, path),
            .stage_root = try self.allocator.dupe(u8, parent.stage_root),
            .kind = kind,
            .hash = try self.allocator.dupe(u8, hash),
            .size = size,
            .executable = executable,
            .staged = staged,
        };
        try self.nodes.put(self.allocator, id, value);
        return value;
    }

    fn cachedInputFileNode(
        self: *Server,
        parent: *Node,
        name: []const u8,
        path: []const u8,
        hash: []const u8,
        size: u64,
        executable: bool,
    ) !*Node {
        const key = try fileNodeCacheKey(self.allocator, name, hash, size, executable);
        errdefer self.allocator.free(key);
        if (self.file_node_cache.get(key)) |existing| {
            self.allocator.free(key);
            return existing;
        }

        const value = try self.allocator.create(Node);
        const id = self.next_node_id;
        self.next_node_id += 1;
        value.* = .{
            .id = id,
            .parent_id = parent.id,
            .name = try self.allocator.dupe(u8, name),
            .path = try self.allocator.dupe(u8, path),
            .stage_root = try self.allocator.dupe(u8, parent.stage_root),
            .kind = .file,
            .hash = try self.allocator.dupe(u8, hash),
            .size = size,
            .executable = executable,
            .staged = false,
        };
        errdefer value.deinit(self.allocator);

        try self.nodes.put(self.allocator, id, value);
        errdefer _ = self.nodes.remove(id);
        try self.file_node_cache.put(self.allocator, key, value);
        return value;
    }

    fn putChild(self: *Server, parent: *Node, child: *Node) !void {
        try parent.children.put(self.allocator, child.name, child);
        try parent.child_order.append(self.allocator, child);
    }

    fn removeChild(self: *Server, parent: *Node, child: *Node) void {
        _ = self;
        _ = parent.children.remove(child.name);
        for (parent.child_order.items, 0..) |candidate, index| {
            if (candidate.id == child.id) {
                _ = parent.child_order.orderedRemove(index);
                break;
            }
        }
    }

    fn createStageFileNode(
        self: *Server,
        header: *const FuseInHeader,
        parent: *Node,
        name: []const u8,
        mode: u32,
        raw_flags: u32,
        keep_fd: ?*std.posix.fd_t,
    ) !*Node {
        try validateName(name);
        const child_path = try joinPath(self.allocator, parent.path, name);
        defer self.allocator.free(child_path);
        const stage_path = try self.stagePath(parent, child_path);
        defer self.allocator.free(stage_path);
        try self.ensureStageParent(stage_path);
        const flags: std.os.linux.O = @bitCast(raw_flags);
        const fd = try createStageFile(stage_path, @intCast(mode & 0o7777), flags.TRUNC);
        errdefer closeFd(fd);
        chownFd(fd, header.uid, header.gid);
        chmodFd(fd, @intCast(mode & 0o7777));

        self.tree_lock.lock();
        defer self.tree_lock.unlock();
        if (parent.children.get(name)) |existing| {
            if (!existing.staged) return error.ReadOnlyFileSystem;
            self.removeChild(parent, existing);
        }
        const node_value = try self.createNode(parent, name, .file, child_path, "", 0, (mode & 0o111) != 0, true);
        try self.putChild(parent, node_value);
        if (keep_fd) |out_fd| {
            out_fd.* = fd;
        } else {
            closeFd(fd);
        }
        return node_value;
    }

    fn stagePath(self: *Server, root: *const Node, path: []const u8) ![:0]u8 {
        if (path.len == 0) return try self.allocator.dupeZ(u8, root.stage_root);
        return try std.fmt.allocPrintSentinel(self.allocator, "{s}/{s}", .{ root.stage_root, path }, 0);
    }

    fn ensureStageParent(self: *Server, path: [:0]const u8) !void {
        const bytes = path[0..path.len];
        const parent_end = std.mem.lastIndexOfScalar(u8, bytes, '/') orelse return;
        if (parent_end == 0) return;
        var index: usize = 1;
        while (index <= parent_end) : (index += 1) {
            if (index != parent_end and bytes[index] != '/') continue;
            const parent = try self.allocator.dupeZ(u8, bytes[0..index]);
            defer self.allocator.free(parent);
            mkdirPath(parent, 0o755) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    fn stageStat(self: *Server, root: *const Node, path: []const u8) !?StageStat {
        Stats.add(&self.stats.stage_stats, 1);
        const full_path = try self.stagePath(root, path);
        defer self.allocator.free(full_path);
        return try statPath(full_path);
    }

    fn attrFor(self: *Server, node_value: *const Node) !FuseAttr {
        if (node_value.staged) {
            if (try self.stageStat(node_value, node_value.path)) |stat| return stat.attr(node_value.id);
        }
        return casAttrFor(node_value);
    }

    fn openBlob(self: *Server, node_value: *Node) !std.posix.fd_t {
        if (!self.cache_blob_fds) return try self.openBlobUnlocked(node_value);
        const cached = node_value.blob_fd.load(.acquire);
        if (cached >= 0) return @intCast(cached);
        node_value.blob_lock.lock();
        defer node_value.blob_lock.unlock();
        return try self.openBlobLocked(node_value);
    }

    fn openBlobLocked(self: *Server, node_value: *Node) !std.posix.fd_t {
        const cached = node_value.blob_fd.load(.acquire);
        if (cached >= 0) return @intCast(cached);
        const fd = try self.openBlobUnlocked(node_value);
        node_value.blob_fd.store(@intCast(fd), .release);
        return fd;
    }

    fn openBlobUnlocked(self: *Server, node_value: *Node) !std.posix.fd_t {
        const path = try self.blobPath(node_value.hash);
        defer self.allocator.free(path);
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        const fd = try openReadOnly(path_z);
        Stats.add(&self.stats.blob_opens, 1);
        return fd;
    }

    fn openPassthroughBacking(self: *Server, node_value: *Node) ?i32 {
        if (!self.passthrough_enabled) {
            Stats.add(&self.stats.passthrough_skip_disabled, 1);
            return null;
        }
        if (node_value.staged) {
            Stats.add(&self.stats.passthrough_skip_staged, 1);
            return null;
        }
        if (node_value.kind != .file) {
            Stats.add(&self.stats.passthrough_skip_non_file, 1);
            return null;
        }
        if (node_value.executable) {
            Stats.add(&self.stats.passthrough_skip_executable, 1);
            return null;
        }
        if (node_value.size == 0) {
            Stats.add(&self.stats.passthrough_skip_empty, 1);
            return null;
        }

        node_value.blob_lock.lock();
        defer node_value.blob_lock.unlock();
        if (node_value.backing_id) |id| return id;

        const fd = if (self.cache_blob_fds)
            self.openBlobLocked(node_value) catch {
                Stats.add(&self.stats.passthrough_open_failures, 1);
                return null;
            }
        else
            self.openBlobUnlocked(node_value) catch {
                Stats.add(&self.stats.passthrough_open_failures, 1);
                return null;
            };
        defer if (!self.cache_blob_fds) closeFd(fd);

        var map = FuseBackingMap{ .fd = @intCast(fd) };
        const rc = std.os.linux.ioctl(self.fuse_fd, fuse_dev_ioc_backing_open, @intFromPtr(&map));
        if (std.posix.errno(rc) != .SUCCESS or rc == 0) {
            Stats.add(&self.stats.passthrough_open_failures, 1);
            return null;
        }
        const backing_id: i32 = @intCast(rc);
        node_value.backing_id = backing_id;
        Stats.add(&self.stats.passthrough_opens, 1);
        return backing_id;
    }

    fn closeBacking(self: *Server, backing_id: i32) void {
        var id: u32 = @intCast(backing_id);
        const rc = std.os.linux.ioctl(self.fuse_fd, fuse_dev_ioc_backing_close, @intFromPtr(&id));
        if (std.posix.errno(rc) == .SUCCESS) {
            Stats.add(&self.stats.passthrough_closes, 1);
        } else {
            Stats.add(&self.stats.passthrough_close_failures, 1);
        }
    }

    fn readBlobAlloc(self: *Server, hash: []const u8) ![]u8 {
        if (std.mem.eql(u8, hash, empty_sha256)) return self.allocator.alloc(u8, 0);
        const path = try self.blobPath(hash);
        defer self.allocator.free(path);
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        const fd = try openReadOnly(path_z);
        defer closeFd(fd);
        const bytes = try readFdAlloc(self.allocator, fd, 64 * 1024 * 1024);
        Stats.add(&self.stats.directory_blob_reads, 1);
        Stats.add(&self.stats.directory_blob_bytes, @intCast(bytes.len));
        return bytes;
    }

    fn cachedDirectory(self: *Server, hash: []const u8) !*const CachedDirectory {
        if (std.mem.eql(u8, hash, empty_sha256)) return &empty_cached_directory;
        if (self.directory_cache.getPtr(hash)) |cached| return cached;

        const bytes = try self.readBlobAlloc(hash);
        defer self.allocator.free(bytes);
        var reader = protobuf.Reader.init(bytes);
        var decoded = try reapi.Directory.decodeOwned(self.allocator, &reader);
        defer decoded.deinit(self.allocator);

        var cached = try buildCachedDirectory(self.allocator, decoded);
        errdefer cached.deinit(self.allocator);
        const key = try self.allocator.dupe(u8, hash);
        errdefer self.allocator.free(key);
        try self.directory_cache.put(self.allocator, key, cached);
        return self.directory_cache.getPtr(hash).?;
    }

    fn blobPath(self: *Server, hash: []const u8) ![]u8 {
        if (hash.len < 2) return error.InvalidDigestHash;
        return try std.fmt.allocPrint(self.allocator, "{s}/{s}/{s}", .{ self.cas_root, hash[0..2], hash });
    }
};

fn nodeHandle(node: *Node) u64 {
    return @intFromPtr(node);
}

fn openHandleValue(handle: *OpenHandle) u64 {
    return @intFromPtr(handle) | open_handle_tag;
}

fn openHandleFromValue(value: u64) ?*OpenHandle {
    if (value == 0 or (value & open_handle_tag) == 0) return null;
    return @ptrFromInt(value & ~open_handle_tag);
}

fn defaultThreadCount() usize {
    const value_ptr = std.c.getenv("ACTIOND_ACTIONDFS_FUSE_THREADS") orelse return default_threads;
    const value = std.mem.sliceTo(value_ptr, 0);
    return std.fmt.parseInt(usize, value, 10) catch default_threads;
}

const DirentItem = struct {
    node: *Node,
    name: []const u8,
    kind: NodeKind,
};

fn direntAt(directory: *Node, offset: u64) ?DirentItem {
    if (offset == 0) return .{ .node = directory, .name = ".", .kind = .directory };
    if (offset == 1) return .{ .node = directory, .name = "..", .kind = .directory };
    const index = std.math.cast(usize, offset - 2) orelse return null;
    if (index >= directory.child_order.items.len) return null;
    const child = directory.child_order.items[index];
    return .{ .node = child, .name = child.name, .kind = child.kind };
}

const StageStat = struct {
    kind: NodeKind,
    size: u64,
    executable: bool,
    mode: u32,
    uid: u32,
    gid: u32,
    nlink: u32,
    blocks: u64,

    fn attr(self: StageStat, ino: u64) FuseAttr {
        return .{
            .ino = ino,
            .size = self.size,
            .blocks = self.blocks,
            .atime = 0,
            .mtime = 0,
            .ctime = 0,
            .atimensec = 0,
            .mtimensec = 0,
            .ctimensec = 0,
            .mode = self.mode,
            .nlink = self.nlink,
            .uid = self.uid,
            .gid = self.gid,
            .rdev = 0,
            .blksize = 4096,
            .flags = 0,
        };
    }
};

const LinuxDirent64 = extern struct {
    ino: u64,
    off: i64,
    reclen: u16,
    type: u8,
};
const linux_dirent64_name_offset = 19;

fn casAttrFor(node: *const Node) FuseAttr {
    const mode: u32 = switch (node.kind) {
        .directory => std.os.linux.S.IFDIR | 0o777,
        .file => std.os.linux.S.IFREG | if (node.executable) @as(u32, 0o555) else @as(u32, 0o444),
    };
    return .{
        .ino = node.id,
        .size = node.size,
        .blocks = (node.size + 511) / 512,
        .atime = 0,
        .mtime = 0,
        .ctime = 0,
        .atimensec = 0,
        .mtimensec = 0,
        .ctimensec = 0,
        .mode = mode,
        .nlink = if (node.kind == .directory) 2 else 1,
        .uid = 0,
        .gid = 0,
        .rdev = 0,
        .blksize = 4096,
        .flags = 0,
    };
}

fn appendDirent(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    ino: u64,
    off: u64,
    kind: NodeKind,
    name: []const u8,
) !void {
    const header = FuseDirent{
        .ino = ino,
        .off = off,
        .namelen = @intCast(name.len),
        .type = switch (kind) {
            .directory => std.os.linux.DT.DIR,
            .file => std.os.linux.DT.REG,
        },
    };
    try out.appendSlice(allocator, std.mem.asBytes(&header));
    try out.appendSlice(allocator, name);
    const aligned = std.mem.alignForward(usize, @sizeOf(FuseDirent) + name.len, 8);
    const padding = aligned - (@sizeOf(FuseDirent) + name.len);
    try out.appendNTimes(allocator, 0, padding);
}

fn appendDirentBounded(
    out: []u8,
    out_len: *usize,
    ino: u64,
    off: u64,
    kind: NodeKind,
    name: []const u8,
) bool {
    const unaligned = @sizeOf(FuseDirent) + name.len;
    const aligned = std.mem.alignForward(usize, unaligned, 8);
    if (out_len.* + aligned > out.len) return false;
    const start = out_len.*;
    const header = FuseDirent{
        .ino = ino,
        .off = off,
        .namelen = @intCast(name.len),
        .type = switch (kind) {
            .directory => std.os.linux.DT.DIR,
            .file => std.os.linux.DT.REG,
        },
    };
    @memcpy(out[start..][0..@sizeOf(FuseDirent)], std.mem.asBytes(&header));
    @memcpy(out[start + @sizeOf(FuseDirent) ..][0..name.len], name);
    @memset(out[start + unaligned ..][0 .. aligned - unaligned], 0);
    out_len.* += aligned;
    return true;
}

fn mountFuse(allocator: std.mem.Allocator, fuse_fd: std.posix.fd_t, mountpoint: []const u8) !void {
    const data = try std.fmt.allocPrintSentinel(
        allocator,
        "fd={d},rootmode=40777,user_id=0,group_id=0,allow_other,default_permissions",
        .{fuse_fd},
        0,
    );
    defer allocator.free(data);
    const source = "actiondfs_fuse";
    const fstype = "fuse";
    const mountpoint_z = try allocator.dupeZ(u8, mountpoint);
    defer allocator.free(mountpoint_z);
    const rc = std.os.linux.mount(source, mountpoint_z.ptr, fstype, std.os.linux.MS.NOSUID | std.os.linux.MS.NODEV | std.os.linux.MS.NOATIME, @intFromPtr(data.ptr));
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .PERM => return error.PermissionDenied,
        .ACCES => return error.AccessDenied,
        else => return error.MountFailed,
    }
}

fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Options {
    var root_hash: ?[]const u8 = null;
    var cas_root: ?[]const u8 = null;
    var stage_root: ?[]const u8 = null;
    var registry_root: ?[]const u8 = null;
    var threads: usize = defaultThreadCount();
    var positional: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--root")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            root_hash = args[i];
        } else if (std.mem.startsWith(u8, arg, "--root=")) {
            root_hash = arg["--root=".len..];
        } else if (std.mem.eql(u8, arg, "--cas")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            cas_root = args[i];
        } else if (std.mem.startsWith(u8, arg, "--cas=")) {
            cas_root = arg["--cas=".len..];
        } else if (std.mem.eql(u8, arg, "--stage")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            stage_root = args[i];
        } else if (std.mem.startsWith(u8, arg, "--stage=")) {
            stage_root = arg["--stage=".len..];
        } else if (std.mem.eql(u8, arg, "--registry")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            registry_root = args[i];
        } else if (std.mem.startsWith(u8, arg, "--registry=")) {
            registry_root = arg["--registry=".len..];
        } else if (std.mem.eql(u8, arg, "--threads")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            threads = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.startsWith(u8, arg, "--threads=")) {
            threads = try std.fmt.parseInt(usize, arg["--threads=".len..], 10);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownArgument;
        } else if (positional == null) {
            positional = arg;
        } else {
            return error.TooManyArguments;
        }
    }
    if (registry_root == null) {
        const root = root_hash orelse return error.MissingArgumentValue;
        if (root.len != 64) return error.InvalidDigestHash;
        if (stage_root == null) return error.MissingArgumentValue;
    } else if (root_hash != null or stage_root != null) {
        return error.UnknownArgument;
    }
    return .{
        .root_hash = if (root_hash) |root| try allocator.dupe(u8, root) else null,
        .cas_root = try allocator.dupe(u8, cas_root orelse return error.MissingArgumentValue),
        .stage_root = if (stage_root) |stage| try allocator.dupe(u8, stage) else null,
        .registry_root = if (registry_root) |registry| try allocator.dupe(u8, registry) else null,
        .mountpoint = try allocator.dupe(u8, positional orelse return error.MissingArgumentValue),
        .threads = threads,
    };
}

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").os.tag != .linux) return error.UnsupportedHost;
    const allocator = std.heap.smp_allocator;
    const arena = init.arena.allocator();
    const raw_args = try init.minimal.args.toSlice(arena);
    const options = try parseArgs(arena, raw_args[1..]);

    const fuse_fd = try openReadWrite("/dev/fuse");
    defer closeFd(fuse_fd);
    try mountFuse(allocator, fuse_fd, options.mountpoint);
    const zero_message_open = envFlag("ACTIOND_ACTIONDFS_FUSE_ZERO_OPEN");
    const negative_lookup_cache = envFlag("ACTIOND_ACTIONDFS_FUSE_NEGATIVE_LOOKUP");
    enable_fuse_stats = envFlag("ACTIOND_ACTIONDFS_FUSE_STATS") and !envFlag("ACTIOND_ACTIONDFS_FUSE_DISABLE_STATS");
    splice_min_bytes = envUsize("ACTIOND_ACTIONDFS_FUSE_SPLICE_MIN_BYTES") orelse default_splice_min_bytes;

    var server = if (options.registry_root) |registry|
        try Server.initRegistry(allocator, fuse_fd, options.cas_root, registry, zero_message_open, negative_lookup_cache)
    else
        try Server.init(allocator, fuse_fd, options.cas_root, options.stage_root.?, options.root_hash.?, zero_message_open, negative_lookup_cache);
    defer server.stats.print();
    defer server.deinit();
    try server.run(options.threads);
}

fn envFlag(comptime name: [:0]const u8) bool {
    const value_ptr = std.c.getenv(name) orelse return false;
    const value = std.mem.sliceTo(value_ptr, 0);
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.ascii.eqlIgnoreCase(value, "false");
}

fn envUsize(comptime name: [:0]const u8) ?usize {
    const value_ptr = std.c.getenv(name) orelse return null;
    const value = std.mem.sliceTo(value_ptr, 0);
    if (value.len == 0) return null;
    return std.fmt.parseInt(usize, value, 10) catch null;
}

fn monotonicNowNs() i128 {
    var ts: std.os.linux.timespec = undefined;
    const rc = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    if (std.os.linux.errno(rc) != .SUCCESS) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn elapsedNs(start_ns: i128) u64 {
    const elapsed = monotonicNowNs() - start_ns;
    if (elapsed <= 0) return 0;
    return @intCast(elapsed);
}

fn bytesAs(comptime T: type, bytes: []u8) *T {
    return @ptrCast(@alignCast(bytes.ptr));
}

fn bytesAsConst(comptime T: type, bytes: []const u8) ?*const T {
    if (bytes.len < @sizeOf(T)) return null;
    return @ptrCast(@alignCast(bytes.ptr));
}

fn validateName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidName;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;
}

fn ioctlIow(comptime kind: u32, comptime number: u32, comptime size: u32) u32 {
    const ioc_write = 1;
    const ioc_nrshift = 0;
    const ioc_typeshift = 8;
    const ioc_sizeshift = 16;
    const ioc_dirshift = 30;
    return (ioc_write << ioc_dirshift) |
        (kind << ioc_typeshift) |
        (number << ioc_nrshift) |
        (size << ioc_sizeshift);
}

fn joinPath(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    try validateName(name);
    if (parent.len == 0) return try allocator.dupe(u8, name);
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, name });
}

fn openReadWrite(path: [:0]const u8) !std.posix.fd_t {
    while (true) {
        const flags: std.os.linux.O = .{ .ACCMODE = .RDWR, .CLOEXEC = true };
        const rc = std.posix.system.open(path.ptr, flags, @as(std.posix.mode_t, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            else => return error.OpenFailed,
        }
    }
}

fn openWriteOnly(path: [:0]const u8) !std.posix.fd_t {
    while (true) {
        const flags: std.os.linux.O = .{ .ACCMODE = .WRONLY, .CLOEXEC = true };
        const rc = std.posix.system.open(path.ptr, flags, @as(std.posix.mode_t, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            else => return error.OpenFailed,
        }
    }
}

fn openReadOnly(path: [:0]const u8) !std.posix.fd_t {
    while (true) {
        const flags: std.os.linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
        const rc = std.posix.system.open(path.ptr, flags, @as(std.posix.mode_t, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            else => return error.OpenFailed,
        }
    }
}

fn openDirectory(path: [:0]const u8) !std.posix.fd_t {
    while (true) {
        const flags: std.os.linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true };
        const rc = std.posix.system.open(path.ptr, flags, @as(std.posix.mode_t, 0));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            .NOTDIR => return error.NotDir,
            else => return error.OpenFailed,
        }
    }
}

fn createStageFile(path: [:0]const u8, mode: std.posix.mode_t, truncate: bool) !std.posix.fd_t {
    while (true) {
        const flags: std.os.linux.O = .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = truncate, .CLOEXEC = true };
        const rc = std.posix.system.open(path.ptr, flags, mode);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            else => return error.OpenFailed,
        }
    }
}

fn mkdirPath(path: [:0]const u8, mode: std.posix.mode_t) !void {
    while (true) {
        const rc = std.os.linux.mkdir(path.ptr, mode);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .EXIST => return error.PathAlreadyExists,
            .ACCES => return error.AccessDenied,
            .NOENT => return error.FileNotFound,
            else => return error.MkdirFailed,
        }
    }
}

fn unlinkPath(path: [:0]const u8) !void {
    while (true) {
        const rc = std.os.linux.unlink(path.ptr);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.UnlinkFailed,
        }
    }
}

fn rmdirPath(path: [:0]const u8) !void {
    while (true) {
        const rc = std.os.linux.unlinkat(std.os.linux.AT.FDCWD, path.ptr, std.os.linux.AT.REMOVEDIR);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.RmdirFailed,
        }
    }
}

fn renamePath(old_path: [:0]const u8, new_path: [:0]const u8) !void {
    while (true) {
        const rc = std.os.linux.rename(old_path.ptr, new_path.ptr);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            .ACCES, .PERM => return error.AccessDenied,
            else => return error.RenameFailed,
        }
    }
}

fn truncatePath(path: [:0]const u8, size: u64) !void {
    const fd = try openWriteOnly(path);
    defer closeFd(fd);
    try truncateFd(fd, size);
}

fn truncateFd(fd: std.posix.fd_t, size: u64) !void {
    while (true) {
        const rc = std.os.linux.ftruncate(fd, @intCast(size));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return,
            .INTR => continue,
            else => return error.TruncateFailed,
        }
    }
}

fn chmodPath(path: [:0]const u8, mode: std.posix.mode_t) void {
    _ = std.os.linux.chmod(path.ptr, mode);
}

fn chmodFd(fd: std.posix.fd_t, mode: std.posix.mode_t) void {
    _ = chmodFdChecked(fd, mode);
}

fn chmodFdChecked(fd: std.posix.fd_t, mode: std.posix.mode_t) bool {
    const rc = std.os.linux.fchmod(fd, mode);
    return std.os.linux.errno(rc) == .SUCCESS;
}

fn chownPath(path: [:0]const u8, uid: u32, gid: u32) void {
    _ = std.os.linux.chown(path.ptr, uid, gid);
}

fn chownFd(fd: std.posix.fd_t, uid: u32, gid: u32) void {
    _ = std.os.linux.fchown(fd, uid, gid);
}

fn statPath(path: [:0]const u8) !?StageStat {
    var statx_value: std.os.linux.Statx = undefined;
    const rc = std.os.linux.statx(
        std.os.linux.AT.FDCWD,
        path.ptr,
        std.os.linux.AT.SYMLINK_NOFOLLOW | std.os.linux.AT.NO_AUTOMOUNT,
        std.os.linux.STATX.BASIC_STATS,
        &statx_value,
    );
    switch (std.os.linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT, .NOTDIR => return null,
        else => return error.StatFailed,
    }
    const mode: u32 = statx_value.mode;
    const kind: NodeKind = if ((mode & std.os.linux.S.IFMT) == std.os.linux.S.IFDIR)
        .directory
    else if ((mode & std.os.linux.S.IFMT) == std.os.linux.S.IFREG)
        .file
    else
        return null;
    return .{
        .kind = kind,
        .size = statx_value.size,
        .executable = (mode & 0o111) != 0,
        .mode = mode,
        .uid = statx_value.uid,
        .gid = statx_value.gid,
        .nlink = statx_value.nlink,
        .blocks = statx_value.blocks,
    };
}

fn getdents64(fd: std.posix.fd_t, buffer: []u8) !usize {
    while (true) {
        const rc = std.os.linux.getdents64(fd, buffer.ptr, buffer.len);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.ReadDirFailed,
        }
    }
}

fn readFd(fd: std.posix.fd_t, buffer: []u8) !usize {
    while (true) {
        const rc = std.posix.system.read(fd, buffer.ptr, buffer.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .NODEV, .BADF => return error.DeviceGone,
            else => return error.ReadFailed,
        }
    }
}

fn readFdAlloc(allocator: std.mem.Allocator, fd: std.posix.fd_t, max_bytes: usize) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [16 * 1024]u8 = undefined;
    while (true) {
        const n = try readFd(fd, &buffer);
        if (n == 0) break;
        if (out.items.len + n > max_bytes) return error.FileTooBig;
        try out.appendSlice(allocator, buffer[0..n]);
    }
    return try out.toOwnedSlice(allocator);
}

fn preadFd(fd: std.posix.fd_t, buffer: []u8, offset: u64) !usize {
    while (true) {
        const rc = std.posix.system.pread(fd, buffer.ptr, buffer.len, @intCast(offset));
        switch (std.posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
}

fn copyFileRangeFd(
    fd_in: std.posix.fd_t,
    off_in: u64,
    fd_out: std.posix.fd_t,
    off_out: u64,
    len: u64,
) !u64 {
    var in_offset: i64 = @intCast(off_in);
    var out_offset: i64 = @intCast(off_out);
    var copied: u64 = 0;
    while (copied < len) {
        const remaining = len - copied;
        const chunk: usize = @intCast(@min(remaining, 0x7ffff000));
        const rc = std.os.linux.syscall6(
            .copy_file_range,
            @as(usize, @bitCast(@as(isize, fd_in))),
            @intFromPtr(&in_offset),
            @as(usize, @bitCast(@as(isize, fd_out))),
            @intFromPtr(&out_offset),
            chunk,
            0,
        );
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) break;
                copied += n;
            },
            .INTR => continue,
            .AGAIN => continue,
            .INVAL, .NOSYS, .OPNOTSUPP, .XDEV => {
                if (copied == 0) return error.CopyFileRangeUnavailable;
                return copied;
            },
            else => {
                if (copied != 0) return copied;
                return error.CopyFileRangeFailed;
            },
        }
    }
    return copied;
}

fn copyFdRangeManual(
    fd_in: std.posix.fd_t,
    off_in: u64,
    fd_out: std.posix.fd_t,
    off_out: u64,
    len: u64,
    scratch: []u8,
) !u64 {
    var copied: u64 = 0;
    const buffer = scratch[0..@min(scratch.len, read_buffer_len)];
    while (copied < len) {
        const remaining = len - copied;
        const read_len: usize = @intCast(@min(remaining, buffer.len));
        if (read_len == 0) break;
        const n = try preadFd(fd_in, buffer[0..read_len], off_in + copied);
        if (n == 0) break;
        try pwriteFdAll(fd_out, buffer[0..n], off_out + copied);
        copied += n;
    }
    return copied;
}

fn spliceFd(fd_in: std.posix.fd_t, off_in: ?*i64, fd_out: std.posix.fd_t, off_out: ?*i64, len: usize, flags: u32) !usize {
    while (true) {
        const rc = std.os.linux.syscall6(
            .splice,
            @as(usize, @bitCast(@as(isize, fd_in))),
            if (off_in) |ptr| @intFromPtr(ptr) else 0,
            @as(usize, @bitCast(@as(isize, fd_out))),
            if (off_out) |ptr| @intFromPtr(ptr) else 0,
            len,
            flags,
        );
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .INVAL, .NOSYS, .PERM, .OPNOTSUPP => return error.SpliceUnavailable,
            .AGAIN => continue,
            else => return error.SpliceFailed,
        }
    }
}

fn pwriteFdAll(fd: std.posix.fd_t, bytes: []const u8, offset: u64) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.os.linux.pwrite(
            fd,
            bytes[written..].ptr,
            bytes.len - written,
            @intCast(offset + written),
        );
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return error.WriteFailed;
                written += n;
            },
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

fn fcntlInt(fd: std.posix.fd_t, cmd: i32, arg: usize) !usize {
    while (true) {
        const rc = std.os.linux.fcntl(fd, cmd, arg);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return error.FcntlFailed,
        }
    }
}

fn writeFdAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[offset..].ptr, bytes.len - offset);
        switch (std.posix.errno(rc)) {
            .SUCCESS => offset += @intCast(rc),
            .INTR => continue,
            .NODEV, .BADF => return error.DeviceGone,
            else => return error.WriteFailed,
        }
    }
}

fn writevFdAll(fd: std.posix.fd_t, header: []const u8, payload: []const u8) !void {
    var iovs = [_]std.posix.iovec_const{
        .{ .base = header.ptr, .len = header.len },
        .{ .base = payload.ptr, .len = payload.len },
    };
    var index: usize = 0;
    const iov_count: usize = if (payload.len == 0) 1 else 2;
    while (index < iov_count) {
        const rc = std.os.linux.writev(fd, iovs[index..].ptr, iov_count - index);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                var written: usize = @intCast(rc);
                if (written == 0) return error.WriteFailed;
                while (written > 0) {
                    if (written >= iovs[index].len) {
                        written -= iovs[index].len;
                        index += 1;
                        if (index >= iov_count) break;
                    } else {
                        iovs[index].base += written;
                        iovs[index].len -= written;
                        written = 0;
                    }
                }
            },
            .INTR => continue,
            .NODEV, .BADF => return error.DeviceGone,
            else => return error.WriteFailed,
        }
    }
}

fn closeFd(fd: std.posix.fd_t) void {
    while (true) switch (std.posix.errno(std.posix.system.close(fd))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return,
    };
}
