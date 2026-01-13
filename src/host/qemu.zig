const std = @import("std");
const builtin = @import("builtin");

pub const SharePath = struct {
    host: []const u8,
    tag: []const u8,
};

pub const Config = struct {
    rootfs: []const u8,
    kernel: ?[]const u8 = null,
    initrd: ?[]const u8 = null,
    cpus: u8 = 4,
    memory_mb: u32 = 4096,
    port: u16 = 8080,
    host_port: u16 = 0,
    share_paths: []const SharePath = &.{},
};

pub const Qemu = struct {
    allocator: std.mem.Allocator,
    config: Config,
    process: ?std.process.Child = null,
    host_port: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) Qemu {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn start(self: *Qemu) !void {
        self.host_port = if (self.config.host_port != 0) self.config.host_port else try findFreePort();

        var args = std.ArrayListUnmanaged([]const u8){};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, qemuBinary());
        try args.append(self.allocator, "-machine");
        try args.append(self.allocator, machineType());
        try args.append(self.allocator, "-accel");
        try args.append(self.allocator, accelType());

        try args.append(self.allocator, "-smp");
        try args.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{self.config.cpus}));

        try args.append(self.allocator, "-m");
        try args.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}", .{self.config.memory_mb}));

        try args.append(self.allocator, "-drive");
        try args.append(self.allocator, try std.fmt.allocPrint(self.allocator, "file={s},format=raw,if=virtio", .{self.config.rootfs}));

        // Direct kernel boot if kernel provided
        if (self.config.kernel) |kernel| {
            try args.append(self.allocator, "-kernel");
            try args.append(self.allocator, kernel);
            if (self.config.initrd) |initrd| {
                try args.append(self.allocator, "-initrd");
                try args.append(self.allocator, initrd);
            }
            try args.append(self.allocator, "-append");
            try args.append(self.allocator, "root=/dev/vda2 console=ttyAMA0 quiet");
        }

        try args.append(self.allocator, "-netdev");
        try args.append(self.allocator, try std.fmt.allocPrint(self.allocator, "user,id=net0,hostfwd=tcp::{d}-:{d}", .{ self.host_port, self.config.port }));
        try args.append(self.allocator, "-device");
        try args.append(self.allocator, "virtio-net-pci,netdev=net0");

        for (self.config.share_paths) |share| {
            try args.append(self.allocator, "-fsdev");
            try args.append(self.allocator, try std.fmt.allocPrint(self.allocator, "local,id={s},path={s},security_model=mapped-xattr", .{ share.tag, share.host }));
            try args.append(self.allocator, "-device");
            try args.append(self.allocator, try std.fmt.allocPrint(self.allocator, "virtio-9p-pci,fsdev={s},mount_tag={s}", .{ share.tag, share.tag }));
        }

        try args.append(self.allocator, "-display");
        try args.append(self.allocator, "none");
        try args.append(self.allocator, "-daemonize");

        var child = std.process.Child.init(args.items, self.allocator);

        try child.spawn();
        self.process = child;

        try self.waitForReady();
    }

    pub fn stop(self: *Qemu) void {
        if (self.process) |*proc| {
            if (proc.stdin) |stdin| {
                stdin.writeAll("system_powerdown\n") catch {};
            }

            std.Thread.sleep(3 * std.time.ns_per_s);
            _ = proc.kill() catch {};
            _ = proc.wait() catch {};
            self.process = null;
        }
    }

    pub fn getWebSocketUrl(self: *Qemu) ![]const u8 {
        return try std.fmt.allocPrint(self.allocator, "ws://127.0.0.1:{d}", .{self.host_port});
    }

    pub fn getPort(self: *Qemu) u16 {
        return self.host_port;
    }

    fn waitForReady(self: *Qemu) !void {
        const deadline = std.time.milliTimestamp() + 60_000;

        while (std.time.milliTimestamp() < deadline) {
            const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, self.host_port);
            if (std.net.tcpConnectToAddress(addr)) |stream| {
                defer stream.close();
                // Try WebSocket handshake
                const req = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGVzdA==\r\nSec-WebSocket-Version: 13\r\n\r\n";
                stream.writeAll(req) catch continue;
                var buf: [256]u8 = undefined;
                const n = stream.read(&buf) catch continue;
                if (n > 0 and std.mem.indexOf(u8, buf[0..n], "101") != null) {
                    return;
                }
            } else |_| {}

            std.Thread.sleep(500 * std.time.ns_per_ms);
        }

        return error.VmBootTimeout;
    }

    fn qemuBinary() []const u8 {
        return switch (builtin.cpu.arch) {
            .aarch64 => "qemu-system-aarch64",
            .x86_64 => "qemu-system-x86_64",
            else => "qemu-system-x86_64",
        };
    }

    fn machineType() []const u8 {
        return switch (builtin.cpu.arch) {
            .aarch64 => "virt",
            .x86_64 => "q35",
            else => "q35",
        };
    }

    fn accelType() []const u8 {
        return switch (builtin.os.tag) {
            .macos => "hvf",
            .linux => "kvm",
            .windows => "whpx",
            else => "tcg",
        };
    }
};

pub fn findFreePort() !u16 {
    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    const bound_addr = server.listen_address;
    return bound_addr.getPort();
}
