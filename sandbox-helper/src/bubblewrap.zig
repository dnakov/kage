const std = @import("std");
const posix = std.posix;

pub const Config = struct {
    uid: ?u32 = null,
    gid: ?u32 = null,
    hostname: []const u8 = "sandbox",
    network: bool = false,
    new_session: bool = true,
    die_with_parent: bool = true,
    ro_bind: []const BindMount = &.{},
    rw_bind: []const BindMount = &.{},
    tmpfs: []const []const u8 = &.{},
    symlinks: []const Symlink = &.{},
    env_vars: []const EnvVar = &.{},
    unset_env: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
};

pub const BindMount = struct {
    src: []const u8,
    dest: []const u8,
};

pub const Symlink = struct {
    target: []const u8,
    link: []const u8,
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

const default_ro_binds = [_]BindMount{
    .{ .src = "/usr", .dest = "/usr" },
    .{ .src = "/lib", .dest = "/lib" },
    .{ .src = "/lib64", .dest = "/lib64" },
    .{ .src = "/bin", .dest = "/bin" },
    .{ .src = "/sbin", .dest = "/sbin" },
    .{ .src = "/etc/resolv.conf", .dest = "/etc/resolv.conf" },
    .{ .src = "/etc/hosts", .dest = "/etc/hosts" },
    .{ .src = "/etc/passwd", .dest = "/etc/passwd" },
    .{ .src = "/etc/group", .dest = "/etc/group" },
    .{ .src = "/etc/ssl", .dest = "/etc/ssl" },
    .{ .src = "/etc/ca-certificates", .dest = "/etc/ca-certificates" },
};

const default_tmpfs = [_][]const u8{
    "/tmp",
    "/run",
    "/var/tmp",
};

const default_symlinks = [_]Symlink{
    .{ .target = "/usr/bin", .link = "/bin" },
    .{ .target = "/usr/sbin", .link = "/sbin" },
    .{ .target = "/usr/lib", .link = "/lib" },
};

pub fn buildArgs(config: Config, command: []const []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    var args = std.ArrayListUnmanaged([]const u8){};

    try args.append(allocator, "/usr/bin/bwrap");

    try args.append(allocator, "--unshare-user");
    try args.append(allocator, "--unshare-pid");
    try args.append(allocator, "--unshare-ipc");
    try args.append(allocator, "--unshare-uts");
    try args.append(allocator, "--unshare-cgroup");

    if (!config.network) {
        try args.append(allocator, "--unshare-net");
    }

    if (config.new_session) {
        try args.append(allocator, "--new-session");
    }

    if (config.die_with_parent) {
        try args.append(allocator, "--die-with-parent");
    }

    try args.append(allocator, "--hostname");
    try args.append(allocator, config.hostname);

    if (config.uid) |uid| {
        try args.append(allocator, "--uid");
        try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{uid}));
    }

    if (config.gid) |gid| {
        try args.append(allocator, "--gid");
        try args.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{gid}));
    }

    for (default_ro_binds) |bind| {
        if (pathExists(bind.src)) {
            try args.append(allocator, "--ro-bind");
            try args.append(allocator, bind.src);
            try args.append(allocator, bind.dest);
        }
    }

    for (config.ro_bind) |bind| {
        try args.append(allocator, "--ro-bind");
        try args.append(allocator, bind.src);
        try args.append(allocator, bind.dest);
    }

    for (config.rw_bind) |bind| {
        try args.append(allocator, "--bind");
        try args.append(allocator, bind.src);
        try args.append(allocator, bind.dest);
    }

    for (default_tmpfs) |path| {
        try args.append(allocator, "--tmpfs");
        try args.append(allocator, path);
    }

    for (config.tmpfs) |path| {
        try args.append(allocator, "--tmpfs");
        try args.append(allocator, path);
    }

    try args.append(allocator, "--proc");
    try args.append(allocator, "/proc");

    try args.append(allocator, "--dev");
    try args.append(allocator, "/dev");

    for (config.unset_env) |name| {
        try args.append(allocator, "--unsetenv");
        try args.append(allocator, name);
    }

    for (config.env_vars) |env| {
        try args.append(allocator, "--setenv");
        try args.append(allocator, env.name);
        try args.append(allocator, env.value);
    }

    if (config.cwd) |cwd| {
        try args.append(allocator, "--chdir");
        try args.append(allocator, cwd);
    }

    try args.append(allocator, "--");

    for (command) |arg| {
        try args.append(allocator, arg);
    }

    return args.toOwnedSlice(allocator);
}

fn pathExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

pub fn exec(config: Config, command: []const []const u8, allocator: std.mem.Allocator) !void {
    const args = try buildArgs(config, command, allocator);

    var argv: [256]?[*:0]const u8 = undefined;
    for (args, 0..) |arg, i| {
        argv[i] = (allocator.dupeZ(u8, arg) catch return error.OutOfMemory).ptr;
    }
    argv[args.len] = null;

    const env = [_:null]?[*:0]const u8{
        "PATH=/usr/local/bin:/usr/bin:/bin",
        "HOME=/tmp",
        "TERM=xterm-256color",
        "IS_SANDBOX=yes",
        null,
    };

    const err = posix.execvpeZ(argv[0].?, @ptrCast(&argv), @ptrCast(&env));
    return err;
}
