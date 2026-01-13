const std = @import("std");
const protocol = @import("protocol");
const ws_server = @import("ws_server.zig");
const process = @import("process.zig");
const user = @import("user.zig");
const fs = @import("fs.zig");

const log = std.log.scoped(.vmd);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port: u16 = blk: {
        const port_str = std.posix.getenv("VMD_PORT") orelse break :blk 8080;
        break :blk std.fmt.parseInt(u16, port_str, 10) catch 8080;
    };

    log.info("starting vmd on port {d}", .{port});

    var server = try ws_server.Server.init(allocator, port);
    defer server.deinit();

    var process_manager = process.ProcessManager.init(allocator);
    defer process_manager.deinit();

    var session_manager = user.SessionManager.init(allocator);
    defer session_manager.deinit();

    log.info("listening for connections...", .{});

    while (true) {
        const conn = allocator.create(ws_server.Connection) catch continue;
        conn.* = server.accept() catch |err| {
            log.err("accept failed: {}", .{err});
            allocator.destroy(conn);
            continue;
        };

        const thread = std.Thread.spawn(.{}, handleConnection, .{ conn, allocator, &process_manager, &session_manager }) catch |err| {
            log.err("thread spawn failed: {}", .{err});
            conn.close();
            allocator.destroy(conn);
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(conn: *ws_server.Connection, allocator: std.mem.Allocator, process_manager: *process.ProcessManager, session_manager: *user.SessionManager) void {
    defer {
        conn.close();
        allocator.destroy(conn);
    }

    conn.handshake() catch |err| {
        log.err("handshake failed: {}", .{err});
        return;
    };

    log.info("new connection", .{});

    while (true) {
        const msg = conn.readMessage() catch |err| {
            log.err("read error: {}", .{err});
            return;
        } orelse {
            log.info("connection closed", .{});
            return;
        };

        handleMessage(conn, msg, allocator, process_manager, session_manager) catch |err| {
            log.err("handle error: {}", .{err});
        };
    }
}

fn handleMessage(conn: *ws_server.Connection, msg: protocol.Message, allocator: std.mem.Allocator, process_manager: *process.ProcessManager, session_manager: *user.SessionManager) !void {
    switch (msg.type) {
        .ping => try sendResponse(conn, .pong, "{}", allocator),
        .spawn => try handleSpawn(conn, msg.payload, allocator, process_manager),
        .stdin => try handleStdin(msg.payload, allocator, process_manager),
        .kill => try handleKill(msg.payload, allocator, process_manager),
        .resize => try handleResize(msg.payload, allocator, process_manager),
        .mount => try handleMount(msg.payload, allocator),
        .unmount => try handleUnmount(msg.payload, allocator),
        .session_create => try handleSessionCreate(conn, msg.payload, allocator, session_manager),
        .session_destroy => try handleSessionDestroy(conn, msg.payload, allocator, session_manager),
        .binary_install => try handleBinaryInstall(conn, msg.payload, allocator),
        .fs_read => try handleFsRead(conn, msg.payload, allocator),
        .load_state => try handleLoadState(conn, msg.payload, allocator),
        .is_running => try handleIsRunning(conn, msg.payload, allocator, process_manager),
        else => {},
    }
}

fn handleSpawn(conn: *ws_server.Connection, payload: []const u8, allocator: std.mem.Allocator, process_manager: *process.ProcessManager) !void {
    const parsed = try std.json.parseFromSlice(protocol.SpawnParams, allocator, payload, .{});
    defer parsed.deinit();

    const proc = process_manager.spawn(parsed.value) catch {
        try sendError(conn, parsed.value.id, protocol.ErrorCode.SPAWN_FAILED, "spawn failed", allocator);
        return;
    };

    const response = try std.json.Stringify.valueAlloc(allocator, protocol.SpawnedResponse{
        .id = parsed.value.id,
        .pid = proc.pid,
        .handle = proc.handle,
    }, .{});
    defer allocator.free(response);

    try sendResponse(conn, .spawned, response, allocator);

    // Start output forwarding and exit monitoring threads
    if (proc.stdout_fd) |fd| {
        _ = try std.Thread.spawn(.{}, forwardOutput, .{ conn, parsed.value.id, fd, protocol.MessageType.stdout, allocator });
    }
    if (proc.stderr_fd) |fd| {
        _ = try std.Thread.spawn(.{}, forwardOutput, .{ conn, parsed.value.id, fd, protocol.MessageType.stderr, allocator });
    }
    _ = try std.Thread.spawn(.{}, waitForExit, .{ conn, parsed.value.id, proc.pid, allocator });
}

fn handleStdin(payload: []const u8, allocator: std.mem.Allocator, process_manager: *process.ProcessManager) !void {
    const parsed = try std.json.parseFromSlice(struct { id: u32, handle: []const u8, data: []const u8 }, allocator, payload, .{});
    defer parsed.deinit();

    if (process_manager.get(parsed.value.handle)) |proc| {
        try proc.writeStdin(parsed.value.data);
    }
}

fn handleKill(payload: []const u8, allocator: std.mem.Allocator, process_manager: *process.ProcessManager) !void {
    const parsed = try std.json.parseFromSlice(struct { handle: []const u8, signal: u8 = 15 }, allocator, payload, .{});
    defer parsed.deinit();

    if (process_manager.get(parsed.value.handle)) |proc| {
        try proc.kill(parsed.value.signal);
    }
}

fn handleResize(payload: []const u8, allocator: std.mem.Allocator, process_manager: *process.ProcessManager) !void {
    const parsed = try std.json.parseFromSlice(struct { id: u32, handle: []const u8, rows: u16, cols: u16 }, allocator, payload, .{});
    defer parsed.deinit();

    if (process_manager.get(parsed.value.handle)) |proc| {
        if (proc.pty_fd) |fd| {
            const winsize = extern struct {
                ws_row: u16,
                ws_col: u16,
                ws_xpixel: u16 = 0,
                ws_ypixel: u16 = 0,
            }{ .ws_row = parsed.value.rows, .ws_col = parsed.value.cols };
            _ = std.os.linux.ioctl(fd, std.os.linux.T.IOCSWINSZ, @intFromPtr(&winsize));
        }
    }
}

fn handleMount(payload: []const u8, allocator: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(protocol.MountParams, allocator, payload, .{});
    defer parsed.deinit();
    try fs.mountVirtioFS(parsed.value.tag, parsed.value.mount_point, parsed.value.read_only, allocator);
}

fn handleUnmount(payload: []const u8, allocator: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(protocol.UnmountParams, allocator, payload, .{});
    defer parsed.deinit();
    try fs.unmount(parsed.value.mount_point, allocator);
}

fn handleSessionCreate(conn: *ws_server.Connection, payload: []const u8, allocator: std.mem.Allocator, session_manager: *user.SessionManager) !void {
    const parsed = try std.json.parseFromSlice(protocol.SessionCreateParams, allocator, payload, .{});
    defer parsed.deinit();

    const session = session_manager.create(parsed.value.uid, parsed.value.username) catch {
        try sendError(conn, 0, protocol.ErrorCode.USER_CREATE_FAILED, "session create failed", allocator);
        return;
    };

    const response = try std.json.Stringify.valueAlloc(allocator, protocol.SessionResponse{
        .uid = session.uid,
        .gid = session.gid,
        .username = session.username,
        .home_dir = session.home_dir,
    }, .{});
    defer allocator.free(response);

    try sendResponse(conn, .ok, response, allocator);
}

fn handleBinaryInstall(conn: *ws_server.Connection, payload: []const u8, allocator: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(protocol.BinaryInstallParams, allocator, payload, .{});
    defer parsed.deinit();

    fs.installBinary(parsed.value.name, parsed.value.data, parsed.value.executable, allocator) catch {
        try sendError(conn, 0, protocol.ErrorCode.INSTALL_FAILED, "install failed", allocator);
        return;
    };

    try sendResponse(conn, .ok, "{}", allocator);
}

fn handleFsRead(conn: *ws_server.Connection, payload: []const u8, allocator: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(protocol.FsReadParams, allocator, payload, .{});
    defer parsed.deinit();

    const data = fs.readFile(parsed.value.path, allocator) catch {
        try sendError(conn, 0, protocol.ErrorCode.INTERNAL_ERROR, "read failed", allocator);
        return;
    };
    defer allocator.free(data);

    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);

    const response = try std.json.Stringify.valueAlloc(allocator, protocol.DataResponse{ .data = encoded }, .{});
    defer allocator.free(response);

    try sendResponse(conn, .data, response, allocator);
}

fn handleLoadState(conn: *ws_server.Connection, payload: []const u8, allocator: std.mem.Allocator) !void {
    const parsed = try std.json.parseFromSlice(protocol.LoadStateParams, allocator, payload, .{});
    defer parsed.deinit();

    const data = fs.readFile(parsed.value.state_path, allocator) catch {
        try sendError(conn, 0, protocol.ErrorCode.INTERNAL_ERROR, "state file not found", allocator);
        return;
    };
    defer allocator.free(data);

    const encoded_len = std.base64.standard.Encoder.calcSize(data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, data);

    const response = try std.json.Stringify.valueAlloc(allocator, protocol.DataResponse{ .data = encoded }, .{});
    defer allocator.free(response);

    try sendResponse(conn, .data, response, allocator);
}

fn handleIsRunning(conn: *ws_server.Connection, payload: []const u8, allocator: std.mem.Allocator, process_manager: *process.ProcessManager) !void {
    const parsed = try std.json.parseFromSlice(protocol.IsRunningParams, allocator, payload, .{});
    defer parsed.deinit();

    const proc = process_manager.get(parsed.value.handle);
    const running = proc != null and proc.?.isRunning();

    const response = try std.json.Stringify.valueAlloc(allocator, protocol.RunningStatusResponse{
        .handle = parsed.value.handle,
        .running = running,
        .pid = if (proc) |p| p.pid else null,
    }, .{});
    defer allocator.free(response);

    try sendResponse(conn, .running_status, response, allocator);
}

fn handleSessionDestroy(conn: *ws_server.Connection, payload: []const u8, allocator: std.mem.Allocator, session_manager: *user.SessionManager) !void {
    const parsed = try std.json.parseFromSlice(protocol.SessionDestroyParams, allocator, payload, .{});
    defer parsed.deinit();

    session_manager.destroy(parsed.value.uid, parsed.value.delete_home, allocator) catch {
        try sendError(conn, 0, protocol.ErrorCode.INTERNAL_ERROR, "session destroy failed", allocator);
        return;
    };

    try sendResponse(conn, .ok, "{}", allocator);
}

fn waitForExit(conn: *ws_server.Connection, id: u32, pid: std.posix.pid_t, allocator: std.mem.Allocator) void {
    const result = std.posix.waitpid(pid, 0);
    const code: i32 = if (result.status & 0x7f == 0) @intCast((result.status >> 8) & 0xff) else -1;

    const response = std.json.Stringify.valueAlloc(allocator, protocol.ExitResponse{
        .id = id,
        .code = code,
    }, .{}) catch return;
    defer allocator.free(response);

    sendResponse(conn, .exit, response, allocator) catch {};
}

fn forwardOutput(conn: *ws_server.Connection, id: u32, fd: std.posix.fd_t, msg_type: protocol.MessageType, allocator: std.mem.Allocator) void {
    var buf: [4096]u8 = undefined;
    const file = std.fs.File{ .handle = fd };

    while (true) {
        const n = file.read(&buf) catch break;
        if (n == 0) break;

        const response = std.json.Stringify.valueAlloc(allocator, protocol.OutputResponse{
            .id = id,
            .data = buf[0..n],
        }, .{}) catch continue;
        defer allocator.free(response);

        sendResponse(conn, msg_type, response, allocator) catch break;
    }
}

fn sendResponse(conn: *ws_server.Connection, msg_type: protocol.MessageType, payload: []const u8, allocator: std.mem.Allocator) !void {
    const msg = protocol.Message{ .type = msg_type, .payload = payload };
    const encoded = try msg.encode(allocator);
    defer allocator.free(encoded);
    try conn.sendBinary(encoded);
}

fn sendError(conn: *ws_server.Connection, id: u32, code: i32, message: []const u8, allocator: std.mem.Allocator) !void {
    const response = try std.json.Stringify.valueAlloc(allocator, protocol.ErrorResponse{
        .id = id,
        .code = code,
        .message = message,
    }, .{});
    defer allocator.free(response);
    try sendResponse(conn, .@"error", response, allocator);
}
