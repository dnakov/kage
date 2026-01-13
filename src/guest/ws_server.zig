const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");

pub const Connection = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,

    pub fn init(stream: std.net.Stream, allocator: std.mem.Allocator) Connection {
        return .{ .stream = stream, .allocator = allocator };
    }

    pub fn handshake(self: *Connection) !void {
        var buf: [4096]u8 = undefined;
        var total: usize = 0;

        while (total < buf.len) {
            const n = try self.stream.read(buf[total..]);
            if (n == 0) return error.ConnectionClosed;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |_| break;
        }

        const key = extractWebSocketKey(buf[0..total]) orelse return error.InvalidHandshake;
        const accept = computeAcceptKey(key);

        var response: [256]u8 = undefined;
        const response_len = (std.fmt.bufPrint(&response, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept}) catch return error.BufferTooSmall).len;
        _ = try self.stream.write(response[0..response_len]);
    }

    pub fn readMessage(self: *Connection) !?protocol.Message {
        var header: [14]u8 = undefined;
        if (try self.stream.read(header[0..2]) != 2) return null;

        const fin = (header[0] & 0x80) != 0;
        _ = fin;
        const opcode = header[0] & 0x0F;
        if (opcode == 0x8) return null; // close frame

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

        var read: usize = 0;
        while (read < payload.len) {
            const n = try self.stream.read(payload[read..]);
            if (n == 0) return error.ConnectionClosed;
            read += n;
        }

        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }

        if (payload.len < 5) {
            self.allocator.free(payload);
            return null;
        }

        const decoded = protocol.Message.decode(payload) catch return null;
        return decoded;
    }

    pub fn sendMessage(self: *Connection, msg: protocol.Message) !void {
        const encoded = try msg.encode(self.allocator);
        defer self.allocator.free(encoded);
        try self.sendBinary(encoded);
    }

    pub fn sendBinary(self: *Connection, data: []const u8) !void {
        var frame: [14]u8 = undefined;
        var frame_len: usize = 2;

        frame[0] = 0x82; // binary frame, fin=1

        if (data.len < 126) {
            frame[1] = @intCast(data.len);
        } else if (data.len < 65536) {
            frame[1] = 126;
            std.mem.writeInt(u16, frame[2..4], @intCast(data.len), .big);
            frame_len = 4;
        } else {
            frame[1] = 127;
            std.mem.writeInt(u64, frame[2..10], data.len, .big);
            frame_len = 10;
        }

        _ = try self.stream.write(frame[0..frame_len]);
        _ = try self.stream.write(data);
    }

    pub fn close(self: *Connection) void {
        self.stream.close();
    }
};

pub const Server = struct {
    listener: std.net.Server,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, port: u16) !Server {
        const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
        const listener = try address.listen(.{ .reuse_address = true });
        return .{ .listener = listener, .allocator = allocator };
    }

    pub fn accept(self: *Server) !Connection {
        const conn = try self.listener.accept();
        return Connection.init(conn.stream, self.allocator);
    }

    pub fn deinit(self: *Server) void {
        self.listener.deinit();
    }
};

fn extractWebSocketKey(request: []const u8) ?[]const u8 {
    const needle = "Sec-WebSocket-Key: ";
    const start = std.mem.indexOf(u8, request, needle) orelse return null;
    const key_start = start + needle.len;
    const key_end = std.mem.indexOfPos(u8, request, key_start, "\r\n") orelse return null;
    return request[key_start..key_end];
}

fn computeAcceptKey(key: []const u8) [28]u8 {
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var hasher = std.crypto.hash.Sha1.init(.{});
    hasher.update(key);
    hasher.update(magic);
    const hash = hasher.finalResult();
    var result: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&result, &hash);
    return result;
}
