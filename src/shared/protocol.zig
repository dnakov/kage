const std = @import("std");

pub const MessageType = enum(u8) {
    // Requests (host -> guest)
    spawn = 0x01,
    stdin = 0x02,
    kill = 0x03,
    resize = 0x04,
    mount = 0x05,
    unmount = 0x06,
    session_create = 0x07,
    binary_install = 0x08,
    fs_read = 0x09,
    load_state = 0x0A,
    is_running = 0x0B,
    session_destroy = 0x0C,

    // Responses (guest -> host)
    spawned = 0x81,
    stdout = 0x82,
    stderr = 0x83,
    exit = 0x84,
    @"error" = 0x85,
    ok = 0x86,
    data = 0x87,
    running_status = 0x88,
    network_status = 0x89,

    // Bidirectional
    ping = 0xF0,
    pong = 0xF1,
};

pub const ErrorCode = struct {
    pub const PARSE_ERROR: i32 = -32700;
    pub const INVALID_REQUEST: i32 = -32600;
    pub const METHOD_NOT_FOUND: i32 = -32601;
    pub const INVALID_PARAMS: i32 = -32602;
    pub const INTERNAL_ERROR: i32 = -32603;
    pub const SPAWN_FAILED: i32 = -32000;
    pub const PROCESS_NOT_FOUND: i32 = -32001;
    pub const MOUNT_FAILED: i32 = -32002;
    pub const USER_CREATE_FAILED: i32 = -32003;
    pub const INSTALL_FAILED: i32 = -32004;
};

pub const SpawnParams = struct {
    id: u32,
    command: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    uid: ?u32 = null,
    gid: ?u32 = null,
    network: bool = false,
    pty: bool = false,
    seccomp_profile: []const u8 = "default",
};

pub const StdinParams = struct {
    id: u32,
    data: []const u8,
};

pub const KillParams = struct {
    id: u32,
    signal: u8 = 15,
};

pub const ResizeParams = struct {
    id: u32,
    rows: u16,
    cols: u16,
};

pub const MountParams = struct {
    tag: []const u8,
    mount_point: []const u8,
    read_only: bool = false,
};

pub const UnmountParams = struct {
    mount_point: []const u8,
};

pub const SessionCreateParams = struct {
    uid: u32,
    username: ?[]const u8 = null,
};

pub const BinaryInstallParams = struct {
    name: []const u8,
    data: []const u8,
    executable: bool = true,
};

pub const FsReadParams = struct {
    path: []const u8,
};

pub const LoadStateParams = struct {
    session_id: []const u8,
    state_path: []const u8,
};

pub const IsRunningParams = struct {
    handle: []const u8,
};

pub const SessionDestroyParams = struct {
    uid: u32,
    delete_home: bool = false,
};

pub const SpawnedResponse = struct {
    id: u32,
    pid: i32,
    handle: []const u8,
};

pub const OutputResponse = struct {
    id: u32,
    data: []const u8,
};

pub const ExitResponse = struct {
    id: u32,
    code: i32,
    signal: ?u8 = null,
};

pub const ErrorResponse = struct {
    id: u32,
    code: i32,
    message: []const u8,
};

pub const SessionResponse = struct {
    uid: u32,
    gid: u32,
    username: []const u8,
    home_dir: []const u8,
};

pub const DataResponse = struct {
    data: []const u8,
};

pub const RunningStatusResponse = struct {
    handle: []const u8,
    running: bool,
    pid: ?i32 = null,
};

pub const NetworkStatusResponse = struct {
    connected: bool,
    interface: []const u8,
    ip_address: ?[]const u8 = null,
};

pub const Message = struct {
    type: MessageType,
    payload: []const u8,

    pub fn encode(self: Message, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayListUnmanaged(u8){};
        errdefer buf.deinit(allocator);
        try buf.append(allocator, @intFromEnum(self.type));
        const writer = buf.writer(allocator);
        try writer.writeInt(u32, @intCast(self.payload.len), .little);
        try buf.appendSlice(allocator, self.payload);
        return buf.toOwnedSlice(allocator);
    }

    pub fn decode(data: []const u8) !Message {
        if (data.len < 5) return error.TooShort;
        return .{
            .type = @enumFromInt(data[0]),
            .payload = data[5..][0..std.mem.readInt(u32, data[1..5], .little)],
        };
    }

    pub fn decodeHeader(data: []const u8) !struct { msg_type: MessageType, len: u32 } {
        if (data.len < 5) return error.TooShort;
        return .{
            .msg_type = @enumFromInt(data[0]),
            .len = std.mem.readInt(u32, data[1..5], .little),
        };
    }
};
