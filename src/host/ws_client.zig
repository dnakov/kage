const std = @import("std");
const protocol = @import("protocol");

pub const SpawnResult = struct {
    id: u32,
    pid: i32,
    handle: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SpawnResult) void {
        self.allocator.free(self.handle);
    }
};

pub const Callbacks = struct {
    onStdout: ?*const fn (id: u32, data: []const u8) void = null,
    onStderr: ?*const fn (id: u32, data: []const u8) void = null,
    onExit: ?*const fn (id: u32, code: i32) void = null,
    onSpawned: ?*const fn (id: u32, pid: i32, handle: []const u8) void = null,
    onError: ?*const fn (id: u32, code: i32, message: []const u8) void = null,
};

pub const Client = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    next_id: u32 = 1,
    callbacks: Callbacks = .{},
    receive_thread: ?std.Thread = null,
    running: bool = true,
    spawn_result: ?SpawnResult = null,
    spawn_error: ?[]const u8 = null,
    spawn_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    spawn_waiting_id: u32 = 0,

    pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !*Client {
        const addr = try std.net.Address.parseIp4(host, port);
        const stream = try std.net.tcpConnectToAddress(addr);

        const client = try allocator.create(Client);
        client.* = .{
            .stream = stream,
            .allocator = allocator,
        };

        try client.handshake(host, port);
        client.receive_thread = try std.Thread.spawn(.{}, receiveLoop, .{client});

        return client;
    }

    fn handshake(self: *Client, host: []const u8, port: u16) !void {
        const key = "dGhlIHNhbXBsZSBub25jZQ==";
        const request = try std.fmt.allocPrint(self.allocator, "GET / HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n", .{ host, port, key });
        defer self.allocator.free(request);

        _ = try self.stream.write(request);

        var buf: [1024]u8 = undefined;
        var total: usize = 0;

        while (total < buf.len) {
            const n = try self.stream.read(buf[total..]);
            if (n == 0) return error.ConnectionClosed;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |_| break;
        }

        if (std.mem.indexOf(u8, buf[0..total], "101") == null) {
            return error.HandshakeFailed;
        }
    }

    pub fn spawn(self: *Client, command: []const u8, args: []const []const u8) !SpawnResult {
        return self.spawnOpts(command, args, false);
    }

    pub fn spawnRaw(self: *Client, command: []const u8, args: []const []const u8) !SpawnResult {
        return self.spawnOpts(command, args, true);
    }

    fn spawnOpts(self: *Client, command: []const u8, args: []const []const u8, network: bool) !SpawnResult {
        const id = self.next_id;
        self.next_id += 1;

        self.spawn_waiting_id = id;
        self.spawn_done.store(false, .release);
        self.spawn_result = null;
        self.spawn_error = null;

        const payload = try jsonStringify(self.allocator, .{
            .id = id,
            .command = command,
            .args = args,
            .network = network,
        });
        defer self.allocator.free(payload);

        try self.sendMessage(.spawn, payload);

        // Wait for spawned response
        while (!self.spawn_done.load(.acquire)) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }

        if (self.spawn_error) |err| {
            defer self.allocator.free(err);
            return error.SpawnFailed;
        }

        return self.spawn_result.?;
    }

    pub fn sendStdin(self: *Client, id: u32, handle: []const u8, data: []const u8) !void {
        const payload = try jsonStringify(self.allocator, .{ .id = id, .handle = handle, .data = data });
        defer self.allocator.free(payload);
        try self.sendMessage(.stdin, payload);
    }

    pub fn kill(self: *Client, handle: []const u8, signal: u8) !void {
        const payload = try jsonStringify(self.allocator, .{ .handle = handle, .signal = signal });
        defer self.allocator.free(payload);
        try self.sendMessage(.kill, payload);
    }

    pub fn ping(self: *Client) !void {
        try self.sendMessage(.ping, "{}");
    }

    fn sendMessage(self: *Client, msg_type: protocol.MessageType, payload: []const u8) !void {
        const msg = protocol.Message{ .type = msg_type, .payload = payload };
        const encoded = try msg.encode(self.allocator);
        defer self.allocator.free(encoded);
        try self.sendBinary(encoded);
    }

    fn sendBinary(self: *Client, data: []const u8) !void {
        var frame: [14]u8 = undefined;
        var frame_len: usize = 2;

        frame[0] = 0x82; // binary, fin=1

        if (data.len < 126) {
            frame[1] = @as(u8, @intCast(data.len)) | 0x80; // masked
            frame_len = 2;
        } else if (data.len < 65536) {
            frame[1] = 126 | 0x80;
            std.mem.writeInt(u16, frame[2..4], @intCast(data.len), .big);
            frame_len = 4;
        } else {
            frame[1] = 127 | 0x80;
            std.mem.writeInt(u64, frame[2..10], data.len, .big);
            frame_len = 10;
        }

        // Mask key (using zeros for simplicity)
        const mask_key = [4]u8{ 0, 0, 0, 0 };
        @memcpy(frame[frame_len..][0..4], &mask_key);
        frame_len += 4;

        _ = try self.stream.write(frame[0..frame_len]);
        _ = try self.stream.write(data); // data XOR 0 = data
    }

    fn receiveLoop(self: *Client) void {
        while (self.running) {
            const msg = self.readMessage() catch |err| {
                if (err == error.ConnectionClosed) break;
                continue;
            };
            if (msg) |m| {
                self.handleMessage(m) catch continue;
            }
        }
    }

    fn readMessage(self: *Client) !?protocol.Message {
        var header: [14]u8 = undefined;
        if (try self.stream.read(header[0..2]) != 2) return null;

        const opcode = header[0] & 0x0F;
        if (opcode == 0x8) return error.ConnectionClosed;

        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        if (payload_len == 126) {
            if (try self.stream.read(header[2..4]) != 2) return null;
            payload_len = std.mem.readInt(u16, header[2..4], .big);
        } else if (payload_len == 127) {
            if (try self.stream.read(header[2..10]) != 8) return null;
            payload_len = std.mem.readInt(u64, header[2..10], .big);
        }

        var mask_key: [4]u8 = undefined;
        if (masked) {
            if (try self.stream.read(&mask_key) != 4) return null;
        }

        if (payload_len > 16 * 1024 * 1024) return error.PayloadTooLarge;

        const payload = try self.allocator.alloc(u8, @intCast(payload_len));
        errdefer self.allocator.free(payload);

        var read_count: usize = 0;
        while (read_count < payload.len) {
            const n = try self.stream.read(payload[read_count..]);
            if (n == 0) return error.ConnectionClosed;
            read_count += n;
        }

        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }

        if (payload.len < 5) return null;
        const decoded = protocol.Message.decode(payload) catch return null;
        return decoded;
    }

    fn handleMessage(self: *Client, msg: protocol.Message) !void {
        switch (msg.type) {
            .stdout => {
                const resp = try std.json.parseFromSlice(protocol.OutputResponse, self.allocator, msg.payload, .{});
                defer resp.deinit();
                if (self.callbacks.onStdout) |f| f(resp.value.id, resp.value.data);
            },
            .stderr => {
                const resp = try std.json.parseFromSlice(protocol.OutputResponse, self.allocator, msg.payload, .{});
                defer resp.deinit();
                if (self.callbacks.onStderr) |f| f(resp.value.id, resp.value.data);
            },
            .exit => {
                const resp = try std.json.parseFromSlice(protocol.ExitResponse, self.allocator, msg.payload, .{});
                defer resp.deinit();
                if (self.callbacks.onExit) |f| f(resp.value.id, resp.value.code);
            },
            .spawned => {
                const resp = try std.json.parseFromSlice(protocol.SpawnedResponse, self.allocator, msg.payload, .{});
                defer resp.deinit();
                if (resp.value.id == self.spawn_waiting_id) {
                    self.spawn_result = .{
                        .id = resp.value.id,
                        .pid = resp.value.pid,
                        .handle = self.allocator.dupe(u8, resp.value.handle) catch "",
                        .allocator = self.allocator,
                    };
                    self.spawn_done.store(true, .release);
                }
                if (self.callbacks.onSpawned) |f| f(resp.value.id, resp.value.pid, resp.value.handle);
            },
            .@"error" => {
                const resp = try std.json.parseFromSlice(protocol.ErrorResponse, self.allocator, msg.payload, .{});
                defer resp.deinit();
                if (resp.value.id == self.spawn_waiting_id and !self.spawn_done.load(.acquire)) {
                    self.spawn_error = self.allocator.dupe(u8, resp.value.message) catch null;
                    self.spawn_done.store(true, .release);
                }
                if (self.callbacks.onError) |f| f(resp.value.id, resp.value.code, resp.value.message);
            },
            .pong => {},
            else => {},
        }
    }

    pub fn close(self: *Client) void {
        self.running = false;
        self.stream.close();
        if (self.receive_thread) |t| t.join();
        self.allocator.destroy(self);
    }
};

fn jsonStringify(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}
