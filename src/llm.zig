const std = @import("std");

const Message = struct {
    role: []const u8 = "user",
    content: []const u8,
};

const Thinking = struct {
    type: []const u8 = "disabled",
    // budget_tokens: u32 = 10000,
};

// const Tools = struct {
//     type: []const u8 = "web_search_20250305",
//     name: []const u8 = "web_search",
//     max_uses: u8 = 5,
// };

const Payload = struct {
    model: []const u8 = "claude-sonnet-4-20250514",
    system: []const u8 =
        \\you are a helpful command-line tool used to solve problems inside the terminal.
        \\Keep answers very concise and to the point; one or two sentences is sufficient.
        \\Your output will always be plain text, so avoid any rich text formatting.
    ,
    max_tokens: u32 = 20000,
    temperature: f32 = 1.0,
    messages: []const Message,
    thinking: Thinking,
    // tools: []const Tools,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8) Client {
        return Client{
            .allocator = allocator,
            .api_key = api_key,
        };
    }

    pub fn query(self: Client, prompt: []const u8) ![]u8 {
        const history = [_]Message{
            .{ .content = prompt },
        };

        const payload = Payload{
            .messages = history[0..],
            .thinking = Thinking{},
        };

        const json = try std.json.stringifyAlloc(self.allocator, payload, .{});
        defer self.allocator.free(json);

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        // Fixed buffer that std.http will use to store the response headers
        var header_buf: [8 * 1024]u8 = undefined; // 8 KiB is plenty for normal HTTP headers

        const uri = try std.Uri.parse("https://api.anthropic.com/v1/messages");
        var request = try http_client.open(
            .POST,
            uri,
            .{
                .server_header_buffer = header_buf[0..],
                .headers = .{
                    .content_type = .{ .override = "application/json" },
                },
                .extra_headers = &[_]std.http.Header{
                    .{ .name = "x-api-key", .value = self.api_key },
                    .{ .name = "anthropic-version", .value = "2023-06-01" },
                },
            },
        );
        defer request.deinit();
        request.transfer_encoding = .{ .content_length = json.len };

        try request.send();
        try request.writeAll(json);
        try request.finish();
        try request.wait();

        const body = try request.reader().readAllAlloc(self.allocator, 64 * 1024);
        defer self.allocator.free(body);

        if (request.response.status != .ok) {
            std.debug.print("Returned {}\n{s}", .{ @intFromEnum(request.response.status), body });
            return error.RemoteError;
        }

        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{ .allocate = .alloc_always });
        defer parsed.deinit();

        const content = parsed.value.object.get("content").?;
        const text = content.array.items[0].object.get("text").?.string;

        return self.allocator.dupe(u8, text);
    }
};
