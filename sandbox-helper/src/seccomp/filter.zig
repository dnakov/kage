const std = @import("std");
const linux = std.os.linux;

pub const SECCOMP_MODE_FILTER = 2;
pub const SECCOMP_FILTER_FLAG_TSYNC = 1;
pub const SECCOMP_RET_ALLOW = 0x7fff0000;
pub const SECCOMP_RET_KILL_PROCESS = 0x80000000;
pub const SECCOMP_RET_ERRNO = 0x00050000;

pub const BPF_LD = 0x00;
pub const BPF_W = 0x00;
pub const BPF_ABS = 0x20;
pub const BPF_JMP = 0x05;
pub const BPF_JEQ = 0x10;
pub const BPF_K = 0x00;
pub const BPF_RET = 0x06;

pub const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

pub const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

pub const Profile = enum {
    default,
    nodejs,
    python,
    minimal,
};

fn bpfStmt(code: u16, k: u32) SockFilter {
    return .{ .code = code, .jt = 0, .jf = 0, .k = k };
}

fn bpfJump(code: u16, k: u32, jt: u8, jf: u8) SockFilter {
    return .{ .code = code, .jt = jt, .jf = jf, .k = k };
}

const dangerous_syscalls = [_]u32{
    @intFromEnum(linux.SYS.ptrace),
    @intFromEnum(linux.SYS.process_vm_readv),
    @intFromEnum(linux.SYS.process_vm_writev),
    @intFromEnum(linux.SYS.mount),
    @intFromEnum(linux.SYS.umount2),
    @intFromEnum(linux.SYS.pivot_root),
    @intFromEnum(linux.SYS.reboot),
    @intFromEnum(linux.SYS.swapon),
    @intFromEnum(linux.SYS.swapoff),
    @intFromEnum(linux.SYS.init_module),
    @intFromEnum(linux.SYS.delete_module),
    @intFromEnum(linux.SYS.finit_module),
    @intFromEnum(linux.SYS.kexec_load),
    @intFromEnum(linux.SYS.kexec_file_load),
    @intFromEnum(linux.SYS.acct),
    @intFromEnum(linux.SYS.settimeofday),
    @intFromEnum(linux.SYS.clock_settime),
    @intFromEnum(linux.SYS.clock_adjtime),
    @intFromEnum(linux.SYS.adjtimex),
};

pub fn getFilter(profile: Profile) []const SockFilter {
    return switch (profile) {
        .default => &default_filter,
        .nodejs => &default_filter,
        .python => &default_filter,
        .minimal => &minimal_filter,
    };
}

const default_filter = blk: {
    var filter: [dangerous_syscalls.len + 3]SockFilter = undefined;

    filter[0] = bpfStmt(BPF_LD | BPF_W | BPF_ABS, 0);

    for (dangerous_syscalls, 0..) |syscall, i| {
        filter[i + 1] = bpfJump(BPF_JMP | BPF_JEQ | BPF_K, syscall, 0, 1);
        if (i + 2 < filter.len - 1) {
            // Continue to next check
        }
    }

    filter[filter.len - 2] = bpfStmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | 1); // EPERM
    filter[filter.len - 1] = bpfStmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);

    break :blk filter;
};

const minimal_filter = [_]SockFilter{
    bpfStmt(BPF_LD | BPF_W | BPF_ABS, 0),

    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.read), 13, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.write), 12, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.openat), 11, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.close), 10, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.fstat), 9, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.mmap), 8, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.mprotect), 7, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.munmap), 6, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.brk), 5, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.exit), 4, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.exit_group), 3, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.rt_sigreturn), 2, 0),
    bpfJump(BPF_JMP | BPF_JEQ | BPF_K, @intFromEnum(linux.SYS.futex), 1, 0),

    bpfStmt(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | 1),
    bpfStmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
};

pub fn applyFilter(profile: Profile) !void {
    const filter = getFilter(profile);
    const prog = SockFprog{
        .len = @intCast(filter.len),
        .filter = filter.ptr,
    };

    const PR_SET_NO_NEW_PRIVS = 38;
    const PR_SET_SECCOMP = 22;

    var result = linux.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
    if (result != 0) return error.SeccompSetupFailed;

    result = linux.prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, @intFromPtr(&prog), 0, 0);
    if (result != 0) return error.SeccompSetupFailed;
}
