const std = @import("std");
const llm = @import("llm.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = std.process.argsAlloc(allocator) catch {
        std.debug.print("Unable to read argv.\n", .{});
        return error.ArgvFailure;
    };
    defer std.process.argsFree(allocator, args);

    // TODO: Hand-roll proper CLI flag parsing.
    // For the moment we treat *all* trailing args as the prompt.
    if (args.len <= 1) {
        printUsage();
        return;
    }

    // TODO: Parse --api-key / --model
    const api_key_env = std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch |err| {
        switch (err) {
            error.EnvironmentVariableNotFound => {
                std.debug.print("Missing API key.  Supply via --api-key or set ANTHROPIC_API_KEY.\n", .{});
            },
            else => {
                std.debug.print("Unable to read ANTHROPIC_API_KEY: {s}\n", .{@errorName(err)});
            },
        }
        return err;
    };

    var prompt_builder = std.ArrayList(u8).init(allocator);
    defer prompt_builder.deinit();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (i > 1) try prompt_builder.append(' ');
        try prompt_builder.appendSlice(args[i]);
    }
    const prompt = try prompt_builder.toOwnedSlice();

    var client = llm.Client.init(allocator, api_key_env);

    const result = client.query(prompt) catch |err| {
        std.debug.print("Query failed: {s}\n", .{@errorName(err)});
        return;
    };

    std.debug.print("Received answer:\n{s}\n", .{result});

    allocator.free(result);
    allocator.free(api_key_env);
}

fn printUsage() void {
    std.debug.print("Usage: bro [--api-key KEY] [--model NAME] <prompt...>\n", .{});
}
