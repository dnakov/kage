const std = @import("std");
const posix = std.posix;

pub const Session = struct {
    uid: u32,
    gid: u32,
    username: []const u8,
    home_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Session) void {
        self.allocator.free(self.username);
        self.allocator.free(self.home_dir);
    }
};

pub const SessionManager = struct {
    sessions: std.AutoHashMapUnmanaged(u32, *Session),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SessionManager {
        return .{
            .sessions = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SessionManager) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.sessions.deinit(self.allocator);
    }

    pub fn create(self: *SessionManager, uid: u32, username_override: ?[]const u8) !*Session {
        if (self.sessions.get(uid)) |existing| {
            return existing;
        }

        const username = if (username_override) |u|
            try self.allocator.dupe(u8, u)
        else
            try std.fmt.allocPrint(self.allocator, "session{d}", .{uid});
        errdefer self.allocator.free(username);

        const home_dir = try std.fmt.allocPrint(self.allocator, "/home/{d}", .{uid});
        errdefer self.allocator.free(home_dir);

        try createSystemUser(uid, uid, username, home_dir, self.allocator);
        try setupHomeDirectory(home_dir, uid, uid);

        const session = try self.allocator.create(Session);
        session.* = .{
            .uid = uid,
            .gid = uid,
            .username = username,
            .home_dir = home_dir,
            .allocator = self.allocator,
        };

        try self.sessions.put(self.allocator, uid, session);
        return session;
    }

    pub fn get(self: *SessionManager, uid: u32) ?*Session {
        return self.sessions.get(uid);
    }

    pub fn destroy(self: *SessionManager, uid: u32, delete_home: bool, allocator: std.mem.Allocator) !void {
        if (self.sessions.fetchRemove(uid)) |entry| {
            const session = entry.value;

            if (delete_home) {
                // Delete home directory
                const home_dir_z = try allocator.dupeZ(u8, session.home_dir);
                defer allocator.free(home_dir_z);

                const rm_pid = try posix.fork();
                if (rm_pid == 0) {
                    const argv = [_:null]?[*:0]const u8{ "/bin/rm", "-rf", home_dir_z, null };
                    const envp = [_:null]?[*:0]const u8{null};
                    const err = posix.execvpeZ("/bin/rm", &argv, &envp);
                    _ = err catch {};
                    posix.exit(1);
                }
                _ = posix.waitpid(rm_pid, 0);
            }

            // Delete user
            const username_z = try allocator.dupeZ(u8, session.username);
            defer allocator.free(username_z);

            const userdel_pid = try posix.fork();
            if (userdel_pid == 0) {
                const argv = [_:null]?[*:0]const u8{ "/usr/sbin/userdel", username_z, null };
                const envp = [_:null]?[*:0]const u8{null};
                const err = posix.execvpeZ("/usr/sbin/userdel", &argv, &envp);
                _ = err catch {};
                posix.exit(1);
            }
            _ = posix.waitpid(userdel_pid, 0);

            session.deinit();
            self.allocator.destroy(session);
        }
    }
};

fn createSystemUser(uid: u32, gid: u32, username: []const u8, home_dir: []const u8, allocator: std.mem.Allocator) !void {
    const uid_str_z = try allocPrintZ(allocator, "{d}", .{uid});
    defer allocator.free(uid_str_z);

    const gid_str_z = try allocPrintZ(allocator, "{d}", .{gid});
    defer allocator.free(gid_str_z);

    const username_z = try allocator.dupeZ(u8, username);
    defer allocator.free(username_z);

    const home_dir_z = try allocator.dupeZ(u8, home_dir);
    defer allocator.free(home_dir_z);

    // Create group first
    const group_pid = try posix.fork();
    if (group_pid == 0) {
        const argv = [_:null]?[*:0]const u8{
            "/usr/sbin/groupadd",
            "--gid",
            gid_str_z,
            "--force",
            username_z,
            null,
        };
        const envp = [_:null]?[*:0]const u8{null};
        const err = posix.execvpeZ("/usr/sbin/groupadd", &argv, &envp);
        _ = err catch {};
        posix.exit(1);
    }
    _ = posix.waitpid(group_pid, 0);

    // Create user
    const user_pid = try posix.fork();
    if (user_pid == 0) {
        const argv = [_:null]?[*:0]const u8{
            "/usr/sbin/useradd",
            "--uid",
            uid_str_z,
            "--gid",
            gid_str_z,
            "--home-dir",
            home_dir_z,
            "--create-home",
            "--shell",
            "/bin/bash",
            username_z,
            null,
        };
        const envp = [_:null]?[*:0]const u8{null};
        const err = posix.execvpeZ("/usr/sbin/useradd", &argv, &envp);
        _ = err catch {};
        posix.exit(1);
    }

    const result = posix.waitpid(user_pid, 0);
    // Exit code 9 means user already exists
    if (result.status != 0 and result.status != 9 * 256) {
        return error.UserCreateFailed;
    }
}

fn setupHomeDirectory(home_dir: []const u8, uid: u32, gid: u32) !void {
    std.fs.makeDirAbsolute(home_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const mnt_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/mnt", .{home_dir});
    defer std.heap.page_allocator.free(mnt_path);
    std.fs.makeDirAbsolute(mnt_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const tmp_path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/tmp", .{home_dir});
    defer std.heap.page_allocator.free(tmp_path);
    std.fs.makeDirAbsolute(tmp_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // chown the home directory
    const chown_pid = try posix.fork();
    if (chown_pid == 0) {
        const uid_gid_z = try allocPrintZ(std.heap.page_allocator, "{d}:{d}", .{ uid, gid });
        const home_dir_z = try std.heap.page_allocator.dupeZ(u8, home_dir);
        const argv = [_:null]?[*:0]const u8{ "/bin/chown", "-R", uid_gid_z, home_dir_z, null };
        const envp = [_:null]?[*:0]const u8{null};
        const err = posix.execvpeZ("/bin/chown", &argv, &envp);
        _ = err catch {};
        posix.exit(1);
    }
    _ = posix.waitpid(chown_pid, 0);
}

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt_str: []const u8, args: anytype) ![:0]u8 {
    const str = try std.fmt.allocPrint(allocator, fmt_str, args);
    const result = try allocator.allocSentinel(u8, str.len, 0);
    @memcpy(result, str);
    allocator.free(str);
    return result;
}
