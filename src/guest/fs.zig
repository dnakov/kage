const std = @import("std");
const posix = std.posix;

pub fn mountVirtioFS(tag: []const u8, mount_point: []const u8, read_only: bool, allocator: std.mem.Allocator) !void {
    std.fs.makeDirAbsolute(mount_point) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var argv = std.ArrayListUnmanaged(?[*:0]const u8){};
    defer argv.deinit(allocator);

    try argv.append(allocator, "/bin/mount");
    try argv.append(allocator, "-t");
    try argv.append(allocator, "virtiofs");
    if (read_only) {
        try argv.append(allocator, "-o");
        try argv.append(allocator, "ro");
    }
    try argv.append(allocator, try allocator.dupeZ(u8, tag));
    try argv.append(allocator, try allocator.dupeZ(u8, mount_point));
    try argv.append(allocator, null);

    const pid = try posix.fork();
    if (pid == 0) {
        const err = posix.execvpeZ(argv.items[0].?, @ptrCast(argv.items.ptr), @ptrCast(&[_:null]?[*:0]const u8{null}));
        _ = err catch {};
        posix.exit(1);
    }

    const result = posix.waitpid(pid, 0);
    if (result.status != 0) {
        return error.MountFailed;
    }
}

pub fn unmount(mount_point: []const u8, allocator: std.mem.Allocator) !void {
    const mount_point_z = try allocator.dupeZ(u8, mount_point);
    defer allocator.free(mount_point_z);

    const pid = try posix.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/bin/umount", mount_point_z, null };
        const envp = [_:null]?[*:0]const u8{null};
        const err = posix.execvpeZ("/bin/umount", &argv, &envp);
        _ = err catch {};
        posix.exit(1);
    }

    const result = posix.waitpid(pid, 0);
    if (result.status != 0) {
        return error.UnmountFailed;
    }
}

pub fn installBinary(name: []const u8, data: []const u8, executable: bool, allocator: std.mem.Allocator) !void {
    const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(data) catch return error.InvalidBase64;
    const buf = try allocator.alloc(u8, decoded_size);
    defer allocator.free(buf);

    std.base64.standard.Decoder.decode(buf, data) catch return error.InvalidBase64;

    const path = try std.fmt.allocPrint(allocator, "/usr/local/bin/{s}", .{name});
    defer allocator.free(path);

    const file = try std.fs.createFileAbsolute(path, .{ .mode = if (executable) 0o755 else 0o644 });
    defer file.close();

    try file.writeAll(buf);
}

pub fn readFile(path: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const stat = try file.stat();
    if (stat.size > 100 * 1024 * 1024) {
        return error.FileTooLarge;
    }

    return try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
}
