const std = @import("std");
const llm = @import("llm.zig");
const wrapper = @import("wrapper.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = std.process.argsAlloc(allocator) catch {
        std.debug.print("Unable to read argv.\n", .{});
        return error.ArgvFailure;
    };
    defer std.process.argsFree(allocator, args);

    if (args.len <= 1) {
        printUsage();
        return;
    }

    const command_args = args[1..];

    // Execute the command and get results
    const command_result = try wrapper.executeCommand(allocator, command_args);
    defer command_result.deinit(allocator);

    // Get API key for LLM
    const api_key_env = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {
                std.debug.print("Missing API key. Set ANTHROPIC_API_KEY environment variable.\n", .{});
            },
            else => {
                std.debug.print("Unable to read ANTHROPIC_API_KEY: {s}\n", .{@errorName(err)});
            },
        }
        return err;
    };
    defer allocator.free(api_key_env);

    // Combine command, stdout, and stderr into single prompt
    var prompt_builder = std.ArrayList(u8).init(allocator);
    defer prompt_builder.deinit();

    try prompt_builder.appendSlice("Command executed: ");
    for (command_args, 0..) |arg, i| {
        if (i > 0) try prompt_builder.append(' ');
        try prompt_builder.appendSlice(arg);
    }

    try prompt_builder.appendSlice("\n\nSTDOUT:\n");
    try prompt_builder.appendSlice(command_result.stdout);

    try prompt_builder.appendSlice("\n\nSTDERR:\n");
    try prompt_builder.appendSlice(command_result.stderr);

    const combined_prompt = try prompt_builder.toOwnedSlice();
    defer allocator.free(combined_prompt);

    // Send to LLM for analysis
    var client = llm.Client.init(allocator, api_key_env);
    const analysis = client.query(combined_prompt) catch |err| {
        std.debug.print("LLM query failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer allocator.free(analysis);

    // Display analysis
    std.debug.print("{s}\n", .{analysis});

    // Exit with same code as the wrapped command
    std.process.exit(command_result.exit_code);
}

fn printUsage() void {
    std.debug.print("Usage: bro <command> [args...]\n", .{});
    std.debug.print("Example: bro cargo build\n", .{});
}
