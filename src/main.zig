const std = @import("std");
const llm = @import("llm.zig");
const wrapper = @import("wrapper.zig");

const WorkerResult = struct {
    analysis: ?[]u8 = null,
    error_msg: ?[]u8 = null,
    exit_code: u8 = 0,

    fn deinit(self: *WorkerResult, allocator: std.mem.Allocator) void {
        if (self.analysis) |analysis| allocator.free(analysis);
        if (self.error_msg) |msg| allocator.free(msg);
    }
};

const SharedState = struct {
    result: WorkerResult = .{},
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Thread.Mutex = .{},

    fn setResult(self: *SharedState, result: WorkerResult) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.result = result;
        self.completed.store(true, .release);
    }

    fn isCompleted(self: *SharedState) bool {
        return self.completed.load(.acquire);
    }

    fn getResult(self: *SharedState) WorkerResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.result;
    }
};

const WorkerContext = struct {
    allocator: std.mem.Allocator,
    command_args: []const []const u8,
    api_key: []const u8,
    shared_state: *SharedState,
};

fn workerThread(context: *WorkerContext) void {
    // Execute the command
    const command_result = wrapper.executeCommand(context.allocator, context.command_args) catch |err| {
        const error_msg = std.fmt.allocPrint(context.allocator, "Command execution failed: {s}", .{@errorName(err)}) catch {
            context.shared_state.setResult(.{ .error_msg = context.allocator.dupe(u8, "Command execution failed") catch null });
            return;
        };
        context.shared_state.setResult(.{ .error_msg = error_msg });
        return;
    };
    defer command_result.deinit(context.allocator);

    // Combine command, stdout, and stderr into single prompt
    var prompt_builder = std.ArrayList(u8).init(context.allocator);
    defer prompt_builder.deinit();

    prompt_builder.appendSlice("Command executed: ") catch {
        context.shared_state.setResult(.{ .error_msg = context.allocator.dupe(u8, "Failed to build prompt") catch null });
        return;
    };

    for (context.command_args, 0..) |arg, i| {
        if (i > 0) prompt_builder.append(' ') catch break;
        prompt_builder.appendSlice(arg) catch break;
    }

    prompt_builder.appendSlice("\n\nSTDOUT:\n") catch {};
    prompt_builder.appendSlice(command_result.stdout) catch {};

    prompt_builder.appendSlice("\n\nSTDERR:\n") catch {};
    prompt_builder.appendSlice(command_result.stderr) catch {};

    const combined_prompt = prompt_builder.toOwnedSlice() catch {
        context.shared_state.setResult(.{ .error_msg = context.allocator.dupe(u8, "Failed to create prompt") catch null });
        return;
    };
    defer context.allocator.free(combined_prompt);

    // Send to LLM for analysis
    var client = llm.Client.init(context.allocator, context.api_key);
    const analysis = client.query(combined_prompt) catch |err| {
        const error_msg = std.fmt.allocPrint(context.allocator, "LLM query failed: {s}", .{@errorName(err)}) catch {
            context.shared_state.setResult(.{ .error_msg = context.allocator.dupe(u8, "LLM query failed") catch null, .exit_code = command_result.exit_code });
            return;
        };
        context.shared_state.setResult(.{ .error_msg = error_msg, .exit_code = command_result.exit_code });
        return;
    };

    // Set successful result
    context.shared_state.setResult(.{ .analysis = analysis, .exit_code = command_result.exit_code });
}

fn showSpinner() void {
    const spinner_chars = "|/-\\";
    var counter: u8 = 0;

    while (true) {
        std.debug.print("\rAnalyzing... {c}", .{spinner_chars[counter % 4]});
        counter += 1;
        std.Thread.sleep(100_000_000); // 100ms

        // simple implementation - check shared state in the future
        // this will be interrupted by the thread completion
    }
}

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

    // Set up shared state and worker context
    var shared_state = SharedState{};
    var worker_context = WorkerContext{
        .allocator = allocator,
        .command_args = command_args,
        .api_key = api_key_env,
        .shared_state = &shared_state,
    };

    const worker = try std.Thread.spawn(.{}, workerThread, .{&worker_context});
    const spinner_chars = "|/-\\";
    var counter: u8 = 0;

    while (!shared_state.isCompleted()) {
        std.debug.print("\rAnalyzing... {c}", .{spinner_chars[counter % 4]});
        counter +%= 1;
        std.time.sleep(100_000_000); // 100ms
    }

    std.debug.print("\r\x1b[K", .{}); // Clear current line
    worker.join();

    // Get result and display
    var result = shared_state.getResult();
    defer result.deinit(allocator);

    if (result.error_msg) |error_msg| {
        std.debug.print("Error: {s}\n", .{error_msg});
        std.process.exit(1);
    }

    if (result.analysis) |analysis| {
        std.debug.print("{s}\n", .{analysis});
    }

    std.process.exit(result.exit_code);
}

fn printUsage() void {
    std.debug.print("Usage: bro <command> [args...]\n", .{});
    std.debug.print("Example: bro cargo build\n", .{});
}
