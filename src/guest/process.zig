const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");
const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("sys/ioctl.h");
});

pub const Process = struct {
    handle: []const u8,
    pid: posix.pid_t,
    stdin_fd: ?posix.fd_t,
    stdout_fd: ?posix.fd_t,
    stderr_fd: ?posix.fd_t,
    pty_fd: ?posix.fd_t,
    uid: ?u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Process) void {
        if (self.pty_fd) |fd| {
            posix.close(fd);
        } else {
            if (self.stdin_fd) |fd| posix.close(fd);
            if (self.stdout_fd) |fd| posix.close(fd);
            if (self.stderr_fd) |fd| posix.close(fd);
        }
        self.allocator.free(self.handle);
    }

    pub fn writeStdin(self: *Process, data: []const u8) !void {
        if (self.stdin_fd) |fd| {
            _ = try posix.write(fd, data);
        }
    }

    pub fn kill(self: *Process, sig: u8) !void {
        try posix.kill(self.pid, sig);
    }

    pub fn isRunning(self: *Process) bool {
        posix.kill(self.pid, 0) catch return false;
        return true;
    }
};

pub const ProcessManager = struct {
    processes: std.StringHashMapUnmanaged(*Process),
    allocator: std.mem.Allocator,
    next_id: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) ProcessManager {
        return .{
            .processes = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProcessManager) void {
        var it = self.processes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.processes.deinit(self.allocator);
    }

    pub fn spawn(self: *ProcessManager, params: protocol.SpawnParams) !*Process {
        const handle = try std.fmt.allocPrint(self.allocator, "proc-{d}", .{self.next_id});
        errdefer self.allocator.free(handle);
        self.next_id += 1;

        var master_fd: posix.fd_t = -1;
        var slave_fd: posix.fd_t = -1;
        var stdin_pipe: [2]posix.fd_t = undefined;
        var stdout_pipe: [2]posix.fd_t = undefined;
        var stderr_pipe: [2]posix.fd_t = undefined;

        if (params.pty) {
            master_fd = c.posix_openpt(c.O_RDWR | c.O_NOCTTY);
            if (master_fd < 0) return error.PtyOpenFailed;
            errdefer posix.close(master_fd);

            if (c.grantpt(master_fd) != 0) return error.PtyGrantFailed;
            if (c.unlockpt(master_fd) != 0) return error.PtyUnlockFailed;

            const slave_name = c.ptsname(master_fd) orelse return error.PtyNameFailed;
            slave_fd = posix.open(std.mem.span(slave_name), .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch return error.PtySlaveOpenFailed;
            errdefer posix.close(slave_fd);
        } else {
            stdin_pipe = try posix.pipe();
            errdefer {
                posix.close(stdin_pipe[0]);
                posix.close(stdin_pipe[1]);
            }

            stdout_pipe = try posix.pipe();
            errdefer {
                posix.close(stdout_pipe[0]);
                posix.close(stdout_pipe[1]);
            }

            stderr_pipe = try posix.pipe();
            errdefer {
                posix.close(stderr_pipe[0]);
                posix.close(stderr_pipe[1]);
            }
        }

        var argv = std.ArrayListUnmanaged(?[*:0]const u8){};
        defer argv.deinit(self.allocator);

        if (!params.network) {
            try argv.append(self.allocator, "/usr/local/bin/sandbox-helper");
            if (params.uid) |uid| {
                const uid_str = try allocPrintZ(self.allocator, "--uid={d}", .{uid});
                try argv.append(self.allocator, uid_str);
            }
            if (params.gid) |gid| {
                const gid_str = try allocPrintZ(self.allocator, "--gid={d}", .{gid});
                try argv.append(self.allocator, gid_str);
            }
            try argv.append(self.allocator, "--no-network");
            const seccomp_str = try allocPrintZ(self.allocator, "--seccomp={s}", .{params.seccomp_profile});
            try argv.append(self.allocator, seccomp_str);
            try argv.append(self.allocator, "--");
        }

        const cmd_z = try self.allocator.dupeZ(u8, params.command);
        try argv.append(self.allocator, cmd_z);

        for (params.args) |arg| {
            const arg_z = try self.allocator.dupeZ(u8, arg);
            try argv.append(self.allocator, arg_z);
        }
        try argv.append(self.allocator, null);

        var envp = std.ArrayListUnmanaged(?[*:0]const u8){};
        defer envp.deinit(self.allocator);

        try envp.append(self.allocator, try self.allocator.dupeZ(u8, "PATH=/usr/local/bin:/usr/bin:/bin"));
        try envp.append(self.allocator, try self.allocator.dupeZ(u8, "HOME=/tmp"));
        try envp.append(self.allocator, try self.allocator.dupeZ(u8, "IS_SANDBOX=yes"));
        if (params.pty) {
            try envp.append(self.allocator, try self.allocator.dupeZ(u8, "TERM=xterm-256color"));
        }
        try envp.append(self.allocator, null);

        const pid = try posix.fork();
        if (pid == 0) {
            if (params.pty) {
                posix.close(master_fd);
                _ = posix.setsid() catch {};
                _ = c.ioctl(slave_fd, c.TIOCSCTTY, @as(c_int, 0));
                _ = posix.dup2(slave_fd, 0) catch posix.exit(1);
                _ = posix.dup2(slave_fd, 1) catch posix.exit(1);
                _ = posix.dup2(slave_fd, 2) catch posix.exit(1);
                if (slave_fd > 2) posix.close(slave_fd);
            } else {
                posix.close(stdin_pipe[1]);
                posix.close(stdout_pipe[0]);
                posix.close(stderr_pipe[0]);

                _ = posix.dup2(stdin_pipe[0], 0) catch posix.exit(1);
                _ = posix.dup2(stdout_pipe[1], 1) catch posix.exit(1);
                _ = posix.dup2(stderr_pipe[1], 2) catch posix.exit(1);

                posix.close(stdin_pipe[0]);
                posix.close(stdout_pipe[1]);
                posix.close(stderr_pipe[1]);
            }

            if (params.cwd) |cwd| {
                posix.chdir(cwd) catch {};
            }

            if (params.network) {
                if (params.gid) |gid| _ = std.os.linux.setgid(gid);
                if (params.uid) |uid| _ = std.os.linux.setuid(uid);
            }

            const err = posix.execvpeZ(argv.items[0].?, @ptrCast(argv.items.ptr), @ptrCast(envp.items.ptr));
            _ = err catch {};
            posix.exit(127);
        }

        const proc = try self.allocator.create(Process);
        if (params.pty) {
            posix.close(slave_fd);
            proc.* = .{
                .handle = handle,
                .pid = pid,
                .pty_fd = master_fd,
                .stdin_fd = master_fd,
                .stdout_fd = master_fd,
                .stderr_fd = null,
                .uid = params.uid,
                .allocator = self.allocator,
            };
        } else {
            posix.close(stdin_pipe[0]);
            posix.close(stdout_pipe[1]);
            posix.close(stderr_pipe[1]);
            proc.* = .{
                .handle = handle,
                .pid = pid,
                .pty_fd = null,
                .stdin_fd = stdin_pipe[1],
                .stdout_fd = stdout_pipe[0],
                .stderr_fd = stderr_pipe[0],
                .uid = params.uid,
                .allocator = self.allocator,
            };
        }

        try self.processes.put(self.allocator, handle, proc);
        return proc;
    }

    pub fn get(self: *ProcessManager, proc_handle: []const u8) ?*Process {
        return self.processes.get(proc_handle);
    }

    pub fn remove(self: *ProcessManager, proc_handle: []const u8) void {
        if (self.processes.fetchRemove(proc_handle)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
    }
};

fn allocPrintZ(allocator: std.mem.Allocator, comptime fmt_str: []const u8, args: anytype) ![:0]u8 {
    const str = try std.fmt.allocPrint(allocator, fmt_str, args);
    const result = try allocator.allocSentinel(u8, str.len, 0);
    @memcpy(result, str);
    allocator.free(str);
    return result;
}
