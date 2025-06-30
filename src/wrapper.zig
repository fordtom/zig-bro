const std = @import("std");

pub const CommandResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn executeCommand(allocator: std.mem.Allocator, command_args: []const []const u8) !CommandResult {
    var process = std.process.Child.init(command_args, allocator);
    process.stdout_behavior = .Pipe;
    process.stderr_behavior = .Pipe;

    try process.spawn();

    const stdout = try process.stdout.?.readToEndAlloc(allocator, 64 * 1024 * 1024);
    const stderr = try process.stderr.?.readToEndAlloc(allocator, 64 * 1024 * 1024);

    const result = try process.wait();

    const exit_code = switch (result) {
        .Exited => |code| code,
        .Signal => 128,
        .Stopped => 128,
        .Unknown => 1,
    };

    return CommandResult{
        .stdout = stdout,
        .stderr = stderr,
        .exit_code = exit_code,
    };
}
