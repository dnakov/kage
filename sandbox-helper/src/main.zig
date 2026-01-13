const std = @import("std");
const bubblewrap = @import("bubblewrap.zig");
const filter = @import("seccomp/filter.zig");

const usage =
    \\Usage: sandbox-helper [OPTIONS] -- COMMAND [ARGS...]
    \\
    \\Options:
    \\  --uid=UID           Run as specified user ID
    \\  --gid=GID           Run as specified group ID
    \\  --no-network        Disable network access
    \\  --network           Enable network access (default: disabled)
    \\  --seccomp=PROFILE   Seccomp profile: default, nodejs, python, minimal
    \\  --ro-bind=SRC:DEST  Add read-only bind mount
    \\  --bind=SRC:DEST     Add read-write bind mount
    \\  --tmpfs=PATH        Add tmpfs mount
    \\  --cwd=PATH          Set working directory
    \\  --help              Show this help
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = bubblewrap.Config{};
    var seccomp_profile: filter.Profile = .default;
    var ro_binds = std.ArrayListUnmanaged(bubblewrap.BindMount){};
    defer ro_binds.deinit(allocator);
    var rw_binds = std.ArrayListUnmanaged(bubblewrap.BindMount){};
    defer rw_binds.deinit(allocator);
    var tmpfs_paths = std.ArrayListUnmanaged([]const u8){};
    defer tmpfs_paths.deinit(allocator);

    var command_start: usize = 1;
    var found_separator = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            command_start = i + 1;
            found_separator = true;
            break;
        }

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            _ = std.posix.write(std.posix.STDOUT_FILENO, usage) catch {};
            std.process.exit(0);
        }

        if (std.mem.startsWith(u8, arg, "--uid=")) {
            config.uid = std.fmt.parseInt(u32, arg[6..], 10) catch {
                std.log.err("invalid uid: {s}", .{arg[6..]});
                std.process.exit(1);
            };
        } else if (std.mem.startsWith(u8, arg, "--gid=")) {
            config.gid = std.fmt.parseInt(u32, arg[6..], 10) catch {
                std.log.err("invalid gid: {s}", .{arg[6..]});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--no-network")) {
            config.network = false;
        } else if (std.mem.eql(u8, arg, "--network")) {
            config.network = true;
        } else if (std.mem.startsWith(u8, arg, "--seccomp=")) {
            const profile_str = arg[10..];
            if (std.mem.eql(u8, profile_str, "default")) {
                seccomp_profile = .default;
            } else if (std.mem.eql(u8, profile_str, "nodejs")) {
                seccomp_profile = .nodejs;
            } else if (std.mem.eql(u8, profile_str, "python")) {
                seccomp_profile = .python;
            } else if (std.mem.eql(u8, profile_str, "minimal")) {
                seccomp_profile = .minimal;
            } else {
                std.log.err("unknown seccomp profile: {s}", .{profile_str});
                std.process.exit(1);
            }
        } else if (std.mem.startsWith(u8, arg, "--ro-bind=")) {
            const spec = arg[10..];
            if (std.mem.indexOf(u8, spec, ":")) |colon| {
                try ro_binds.append(allocator, .{
                    .src = spec[0..colon],
                    .dest = spec[colon + 1 ..],
                });
            } else {
                try ro_binds.append(allocator, .{ .src = spec, .dest = spec });
            }
        } else if (std.mem.startsWith(u8, arg, "--bind=")) {
            const spec = arg[7..];
            if (std.mem.indexOf(u8, spec, ":")) |colon| {
                try rw_binds.append(allocator, .{
                    .src = spec[0..colon],
                    .dest = spec[colon + 1 ..],
                });
            } else {
                try rw_binds.append(allocator, .{ .src = spec, .dest = spec });
            }
        } else if (std.mem.startsWith(u8, arg, "--tmpfs=")) {
            try tmpfs_paths.append(allocator, arg[8..]);
        } else if (std.mem.startsWith(u8, arg, "--cwd=")) {
            config.cwd = arg[6..];
        } else if (arg[0] == '-') {
            std.log.err("unknown option: {s}", .{arg});
            std.process.exit(1);
        } else {
            command_start = i;
            break;
        }
    }

    if (!found_separator and command_start >= args.len) {
        _ = std.posix.write(std.posix.STDERR_FILENO, usage) catch {};
        std.process.exit(1);
    }

    const command = args[command_start..];
    if (command.len == 0) {
        _ = std.posix.write(std.posix.STDERR_FILENO, "error: no command specified\n") catch {};
        _ = std.posix.write(std.posix.STDERR_FILENO, usage) catch {};
        std.process.exit(1);
    }

    config.ro_bind = ro_binds.items;
    config.rw_bind = rw_binds.items;
    config.tmpfs = tmpfs_paths.items;

    bubblewrap.exec(config, command, allocator) catch |err| {
        std.log.err("exec failed: {}", .{err});
        std.process.exit(127);
    };
}

test "parse uid" {
    const uid = std.fmt.parseInt(u32, "1001", 10) catch unreachable;
    try std.testing.expectEqual(@as(u32, 1001), uid);
}
