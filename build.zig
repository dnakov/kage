const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    // Shared protocol module
    const protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/protocol.zig"),
    });

    // Host binary (native)
    const host_target = b.standardTargetOptions(.{});
    const host = b.addExecutable(.{
        .name = "vmctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host/main.zig"),
            .target = host_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = protocol_mod },
            },
        }),
    });
    b.installArtifact(host);

    const run_cmd = b.addRunArtifact(host);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    b.step("run", "Run vmctl").dependOn(&run_cmd.step);

    // Guest binary (Linux aarch64)
    const guest_arm_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const guest_arm = b.addExecutable(.{
        .name = "vmd-aarch64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/guest/main.zig"),
            .target = guest_arm_target,
            .optimize = if (optimize == .Debug) .Debug else .ReleaseSafe,
            .link_libc = true,
            .imports = &.{
                .{ .name = "protocol", .module = protocol_mod },
            },
        }),
    });
    b.installArtifact(guest_arm);

    // Guest binary (Linux x86_64)
    const guest_x86_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
        .abi = .musl,
    });
    const guest_x86 = b.addExecutable(.{
        .name = "vmd-x86_64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/guest/main.zig"),
            .target = guest_x86_target,
            .optimize = if (optimize == .Debug) .Debug else .ReleaseSafe,
            .link_libc = true,
            .imports = &.{
                .{ .name = "protocol", .module = protocol_mod },
            },
        }),
    });
    b.installArtifact(guest_x86);

    // Sandbox helper (Linux aarch64)
    const sandbox_arm = b.addExecutable(.{
        .name = "sandbox-helper-aarch64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sandbox-helper/src/main.zig"),
            .target = guest_arm_target,
            .optimize = if (optimize == .Debug) .Debug else .ReleaseSafe,
            .link_libc = true,
        }),
    });
    b.installArtifact(sandbox_arm);

    // Sandbox helper (Linux x86_64)
    const sandbox_x86 = b.addExecutable(.{
        .name = "sandbox-helper-x86_64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("sandbox-helper/src/main.zig"),
            .target = guest_x86_target,
            .optimize = if (optimize == .Debug) .Debug else .ReleaseSafe,
            .link_libc = true,
        }),
    });
    b.installArtifact(sandbox_x86);

    // Build steps
    const host_step = b.step("host", "Build host binary");
    host_step.dependOn(&b.addInstallArtifact(host, .{}).step);

    const guest_step = b.step("guest", "Build guest binaries (both archs)");
    guest_step.dependOn(&b.addInstallArtifact(guest_arm, .{}).step);
    guest_step.dependOn(&b.addInstallArtifact(guest_x86, .{}).step);

    const sandbox_step = b.step("sandbox", "Build sandbox-helper (both archs)");
    sandbox_step.dependOn(&b.addInstallArtifact(sandbox_arm, .{}).step);
    sandbox_step.dependOn(&b.addInstallArtifact(sandbox_x86, .{}).step);

    // Tests (native)
    const host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/host/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = protocol_mod },
            },
        }),
    });
    const run_host_tests = b.addRunArtifact(host_tests);

    const guest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/guest/main.zig"),
            .target = b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = protocol_mod },
            },
        }),
    });
    const run_guest_tests = b.addRunArtifact(guest_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_host_tests.step);
    test_step.dependOn(&run_guest_tests.step);
}
