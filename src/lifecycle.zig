const std = @import("std");
const builtin = @import("builtin");

extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, milliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub fn sleepMs(milliseconds: u32) void {
    if (builtin.os.tag == .windows) {
        Sleep(milliseconds);
    } else {
        const Timespec = extern struct { sec: isize, ns: isize };
        const request: Timespec = .{ .sec = milliseconds / 1000, .ns = @as(isize, milliseconds % 1000) * 1_000_000 };
        _ = std.os.linux.syscall2(.nanosleep, @intFromPtr(&request), 0);
    }
}

// Readiness does not reap: ownership stays with the atomic state machine.
pub fn exited(child: *const std.process.Child) bool {
    if (builtin.os.tag == .windows) {
        return WaitForSingleObject(child.id.?, 0) == 0;
    } else {
        // Linux waitid with WNOWAIT leaves the status available to Child.wait.
        var info: extern struct {
            signo: i32 = 0,
            errno: i32 = 0,
            code: i32 = 0,
            padding: i32 = 0,
            pid: i32 = 0,
            rest: [108]u8 = @splat(0),
        } = .{};
        const result = std.os.linux.syscall5(.waitid, 1, @intCast(child.id.?), @intFromPtr(&info), 0x01000005, 0);
        return result == 0 and info.pid != 0;
    }
}

pub fn reapBounded(child: *std.process.Child, io: std.Io, grace_ms: u32) void {
    var elapsed: u32 = 0;
    while (elapsed < grace_ms) : (elapsed += 10) {
        if (exited(child)) {
            _ = child.wait(io) catch {};
            return;
        }
        sleepMs(10);
    }
    child.kill(io);
}

// EndOfStream is the I/O abstraction's EOF signal, including broken pipes.
pub fn readSize(result: @typeInfo(@TypeOf(std.Io.File.readStreaming)).@"fn".return_type.?) !usize {
    return result catch |err| {
        if (err == error.EndOfStream) return 0;
        return err;
    };
}

test "read failures remain failures" {
    try std.testing.expectEqual(@as(usize, 0), try readSize(error.EndOfStream));
    try std.testing.expectError(error.InputOutput, readSize(error.InputOutput));
    try std.testing.expectError(error.AccessDenied, readSize(error.AccessDenied));
}
