const std = @import("std");

/// Map Claude Code model names to Zed-compatible names
pub fn normalizeModelName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "claude-opus-4-6")) return "claude-opus-4-6";
    if (std.mem.startsWith(u8, name, "claude-opus-4-5")) return "claude-opus-4-5";
    if (std.mem.startsWith(u8, name, "claude-opus-4-1")) return "claude-opus-4-1";
    if (std.mem.startsWith(u8, name, "claude-sonnet-4-5")) return "claude-sonnet-4-5";
    if (std.mem.startsWith(u8, name, "claude-sonnet-4")) return "claude-sonnet-4";
    if (std.mem.startsWith(u8, name, "claude-3-7-sonnet")) return "claude-3-7-sonnet";
    if (std.mem.startsWith(u8, name, "claude-haiku-4-5")) return "claude-haiku-4-5";
    return name;
}

/// Get Zed provider string for a model
pub fn getProvider(model: []const u8) []const u8 {
    if (std.mem.startsWith(u8, model, "claude")) return "anthropic";
    if (std.mem.startsWith(u8, model, "gpt-")) return "open_ai";
    if (std.mem.startsWith(u8, model, "gemini")) return "google";
    if (std.mem.startsWith(u8, model, "grok")) return "x_ai";
    return "anthropic";
}

pub fn extractModel(root: std.json.Value) []const u8 {
    if (root.object.get("model")) |mv| {
        if (mv == .string) return normalizeModelName(mv.string);
    }
    return "claude-sonnet-4-5";
}

pub fn extractModelFromBody(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return "claude-sonnet-4-5";
    defer parsed.deinit();
    if (parsed.value.object.get("model")) |mv| {
        if (mv == .string) return allocator.dupe(u8, mv.string) catch return "claude-sonnet-4-5";
    }
    return "claude-sonnet-4-5";
}

/// Extract system text from Anthropic-format system field (string or array)
fn extractSystemText(allocator: std.mem.Allocator, parsed: std.json.Value) ?[]const u8 {
    const sys = parsed.object.get("system") orelse return null;
    if (sys == .string) return sys.string;
    if (sys == .array) {
        var sys_buf: std.io.Writer.Allocating = .init(allocator);
        defer sys_buf.deinit();
        for (sys.array.items) |item| {
            if (item != .object) continue;
            const text_val = item.object.get("text") orelse continue;
            if (text_val != .string) continue;
            if (sys_buf.written().len > 0) sys_buf.writer.writeAll("\n\n") catch continue;
            sys_buf.writer.writeAll(text_val.string) catch continue;
        }
        if (sys_buf.written().len > 0) return allocator.dupe(u8, sys_buf.written()) catch null;
    }
    return null;
}

fn fakeUuid(buf: *[36]u8) []const u8 {
    const hex = "0123456789abcdef";
    var rng = std.Random.DefaultPrng.init(@bitCast(std.time.timestamp()));
    const r = rng.random();
    for (buf, 0..) |*c, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            c.* = '-';
        } else {
            c.* = hex[r.intRangeAtMost(u4, 0, 15)];
        }
    }
    return buf;
}

fn writeMessage(w: *std.io.Writer, msg: std.json.Value) !void {
    if (msg != .object) return;
    const role = switch (msg.object.get("role") orelse return) {
        .string => |s| s,
        else => return,
    };
    const content = msg.object.get("content") orelse return;
    try w.print("{{\"role\":\"{s}\",\"content\":", .{role});
    switch (content) {
        .string => {
            try w.writeAll("[{\"type\":\"text\",\"text\":");
            try std.json.Stringify.encodeJsonString(content.string, .{}, w);
            try w.writeAll("}]");
        },
        .array => try std.json.Stringify.value(content, .{}, w),
        else => try w.writeAll("[]"),
    }
    try w.writeAll("}");
}

/// Write Anthropic-native message (passthrough content as-is, including tool_use/tool_result)
fn writeAnthropicMessage(w: *std.io.Writer, msg: std.json.Value) !void {
    if (msg != .object) return;
    // Passthrough the entire message object as-is for Anthropic native format
    try std.json.Stringify.value(msg, .{}, w);
}

/// Write message with OpenAI->Anthropic tool support conversion
fn writeMessageWithToolSupport(w: *std.io.Writer, msg: std.json.Value, allocator: std.mem.Allocator) !void {
    if (msg != .object) return;
    const role = switch (msg.object.get("role") orelse return) {
        .string => |s| s,
        else => return,
    };

    // Handle tool call results (OpenAI role=tool -> Anthropic role=user with tool_result)
    if (std.mem.eql(u8, role, "tool")) {
        const tool_call_id = switch (msg.object.get("tool_call_id") orelse return) { .string => |s| s, else => return };
        const content = msg.object.get("content") orelse return;
        try w.writeAll("{\"role\":\"user\",\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":");
        try std.json.Stringify.encodeJsonString(tool_call_id, .{}, w);
        try w.writeAll(",\"content\":");
        switch (content) {
            .string => try std.json.Stringify.encodeJsonString(content.string, .{}, w),
            else => try std.json.Stringify.value(content, .{}, w),
        }
        try w.writeAll("}]}");
        return;
    }

    // Handle assistant messages with tool_calls (OpenAI -> Anthropic tool_use)
    if (std.mem.eql(u8, role, "assistant")) {
        const tool_calls = msg.object.get("tool_calls");
        const content = msg.object.get("content");
        if (tool_calls != null and tool_calls.? == .array) {
            try w.writeAll("{\"role\":\"assistant\",\"content\":[");
            var wrote_any = false;
            // Include text content if present
            if (content) |c| {
                switch (c) {
                    .string => |s| {
                        if (s.len > 0) {
                            try w.writeAll("{\"type\":\"text\",\"text\":");
                            try std.json.Stringify.encodeJsonString(s, .{}, w);
                            try w.writeAll("}");
                            wrote_any = true;
                        }
                    },
                    else => {},
                }
            }
            // Convert tool_calls to tool_use blocks
            for (tool_calls.?.array.items) |tc| {
                if (tc != .object) continue;
                if (wrote_any) try w.writeAll(",");
                wrote_any = true;
                try w.writeAll("{\"type\":\"tool_use\"");
                if (tc.object.get("id")) |id| {
                    try w.writeAll(",\"id\":"); try std.json.Stringify.value(id, .{}, w);
                }
                if (tc.object.get("function")) |func| {
                    if (func == .object) {
                        if (func.object.get("name")) |n| {
                            try w.writeAll(",\"name\":"); try std.json.Stringify.value(n, .{}, w);
                        }
                        if (func.object.get("arguments")) |args| {
                            try w.writeAll(",\"input\":");
                            if (args == .string) {
                                // Parse JSON string arguments into object
                                const parsed_args = std.json.parseFromSlice(std.json.Value, allocator, args.string, .{}) catch {
                                    try w.writeAll("{}");
                                    try w.writeAll("}");
                                    continue;
                                };
                                defer parsed_args.deinit();
                                try std.json.Stringify.value(parsed_args.value, .{}, w);
                            } else {
                                try std.json.Stringify.value(args, .{}, w);
                            }
                        } else {
                            try w.writeAll(",\"input\":{}");
                        }
                    }
                }
                try w.writeAll("}");
            }
            try w.writeAll("]}");
            return;
        }
    }

    // Default: regular message
    try writeMessage(w, msg);
}

/// Build Zed completions payload from client request body.
pub fn buildZedPayload(allocator: std.mem.Allocator, body: []const u8, is_anthropic: bool) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const model = extractModel(parsed.value);
    const provider = getProvider(model);

    var zed_body: std.io.Writer.Allocating = .init(allocator);
    errdefer zed_body.deinit();
    const w = &zed_body.writer;

    var uuid_buf1: [36]u8 = undefined;
    var uuid_buf2: [36]u8 = undefined;
    try w.print("{{\"thread_id\":\"{s}\",\"prompt_id\":\"{s}\",\"intent\":\"user_prompt\",\"provider\":\"{s}\",\"model\":\"{s}\",\"provider_request\":{{", .{
        fakeUuid(&uuid_buf1), fakeUuid(&uuid_buf2), provider, model,
    });

    if (std.mem.eql(u8, provider, "anthropic")) {
        try buildAnthropicRequest(allocator, w, parsed.value, model, is_anthropic);
    } else if (std.mem.eql(u8, provider, "open_ai")) {
        try buildOpenAIRequest(allocator, w, parsed.value, model, is_anthropic);
    } else if (std.mem.eql(u8, provider, "google")) {
        try buildGoogleRequest(allocator, w, parsed.value, model, is_anthropic);
    } else {
        try buildXAIRequest(allocator, w, parsed.value, model, is_anthropic);
    }

    try w.writeAll("}}");
    return try zed_body.toOwnedSlice();
}

fn buildAnthropicRequest(allocator: std.mem.Allocator, w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {
    try w.print("\"model\":\"{s}\",", .{model});
    if (parsed.object.get("max_tokens")) |mt| {
        switch (mt) { .integer => |i| try w.print("\"max_tokens\":{d},", .{i}), else => try w.writeAll("\"max_tokens\":8192,") }
    } else try w.writeAll("\"max_tokens\":8192,");

    if (is_anthropic) {
        if (extractSystemText(allocator, parsed)) |sys_text| {
            try w.writeAll("\"system\":");
            try std.json.Stringify.encodeJsonString(sys_text, .{}, w);
            try w.writeAll(",");
        }
    }
    if (parsed.object.get("temperature")) |temp| {
        try w.writeAll("\"temperature\":"); try std.json.Stringify.value(temp, .{}, w); try w.writeAll(",");
    }
    if (parsed.object.get("thinking")) |thinking| {
        try w.writeAll("\"thinking\":"); try std.json.Stringify.value(thinking, .{}, w); try w.writeAll(",");
    }
    // Tools support
    if (is_anthropic) {
        // Anthropic native format: tools already in correct format
        if (parsed.object.get("tools")) |tools| {
            try w.writeAll("\"tools\":"); try std.json.Stringify.value(tools, .{}, w); try w.writeAll(",");
        }
        if (parsed.object.get("tool_choice")) |tc| {
            try w.writeAll("\"tool_choice\":"); try std.json.Stringify.value(tc, .{}, w); try w.writeAll(",");
        }
    } else {
        // OpenAI format -> Anthropic format conversion
        if (parsed.object.get("tools")) |tools| {
            if (tools == .array) {
                try w.writeAll("\"tools\":[");
                var first = true;
                for (tools.array.items) |tool| {
                    if (tool != .object) continue;
                    const func = tool.object.get("function") orelse continue;
                    if (func != .object) continue;
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{\"name\":");
                    if (func.object.get("name")) |n| try std.json.Stringify.value(n, .{}, w) else try w.writeAll("\"\"");
                    if (func.object.get("description")) |d| {
                        try w.writeAll(",\"description\":"); try std.json.Stringify.value(d, .{}, w);
                    }
                    if (func.object.get("parameters")) |p| {
                        try w.writeAll(",\"input_schema\":"); try std.json.Stringify.value(p, .{}, w);
                    }
                    try w.writeAll("}");
                }
                try w.writeAll("],");
            }
        }
        if (parsed.object.get("tool_choice")) |tc| {
            // OpenAI tool_choice -> Anthropic tool_choice
            if (tc == .string) {
                if (std.mem.eql(u8, tc.string, "auto")) {
                    try w.writeAll("\"tool_choice\":{\"type\":\"auto\"},");
                } else if (std.mem.eql(u8, tc.string, "required")) {
                    try w.writeAll("\"tool_choice\":{\"type\":\"any\"},");
                } else if (std.mem.eql(u8, tc.string, "none")) {
                    // Don't send tool_choice for "none", just omit tools
                }
            } else if (tc == .object) {
                try w.writeAll("\"tool_choice\":"); try std.json.Stringify.value(tc, .{}, w); try w.writeAll(",");
            }
        }
    }
    try w.writeAll("\"messages\":[");
    if (parsed.object.get("messages")) |msgs| {
        if (msgs == .array) for (msgs.array.items, 0..) |msg, i| {
            if (i > 0) try w.writeAll(",");
            if (is_anthropic) {
                try writeAnthropicMessage(w, msg);
            } else {
                try writeMessageWithToolSupport(w, msg, allocator);
            }
        };
    }
    try w.writeAll("]");
}

fn buildOpenAIRequest(allocator: std.mem.Allocator, w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {
    try w.print("\"model\":\"{s}\",\"stream\":true,\"input\":[", .{model});
    var wrote_any = false;

    if (is_anthropic) {
        if (extractSystemText(allocator, parsed)) |sys_text| {
            try w.writeAll("{\"type\":\"message\",\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":");
            try std.json.Stringify.encodeJsonString(sys_text, .{}, w);
            try w.writeAll("}]}");
            wrote_any = true;
        }
    }

    if (parsed.object.get("messages")) |msgs| {
        if (msgs == .array) for (msgs.array.items) |msg| {
            if (msg != .object) continue;
            const role = switch (msg.object.get("role") orelse continue) { .string => |s| s, else => continue };
            const content = msg.object.get("content") orelse continue;
            if (wrote_any) try w.writeAll(",");
            wrote_any = true;
            const content_type = if (std.mem.eql(u8, role, "assistant")) "output_text" else "input_text";
            try w.print("{{\"type\":\"message\",\"role\":\"{s}\",\"content\":[", .{role});
            switch (content) {
                .string => |s| {
                    try w.print("{{\"type\":\"{s}\",\"text\":", .{content_type});
                    try std.json.Stringify.encodeJsonString(s, .{}, w);
                    try w.writeAll("}");
                },
                .array => {
                    for (content.array.items, 0..) |item, ci| {
                        if (ci > 0) try w.writeAll(",");
                        if (item == .object) {
                            const text_val = item.object.get("text") orelse continue;
                            if (text_val != .string) continue;
                            try w.print("{{\"type\":\"{s}\",\"text\":", .{content_type});
                            try std.json.Stringify.encodeJsonString(text_val.string, .{}, w);
                            try w.writeAll("}");
                        }
                    }
                },
                else => {},
            }
            try w.writeAll("]}");
        };
    }
    try w.writeAll("]");
}

fn buildGoogleRequest(allocator: std.mem.Allocator, w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {
    try w.print("\"model\":\"models/{s}\",", .{model});

    if (is_anthropic) {
        if (extractSystemText(allocator, parsed)) |sys_text| {
            try w.writeAll("\"systemInstruction\":{\"parts\":[{\"text\":");
            try std.json.Stringify.encodeJsonString(sys_text, .{}, w);
            try w.writeAll("}]},");
        }
    }

    try w.writeAll("\"generationConfig\":{\"candidateCount\":1,\"stopSequences\":[],\"temperature\":1.0},");

    // Tools support for Google format
    if (is_anthropic) {
        // Anthropic tools -> Google functionDeclarations
        if (parsed.object.get("tools")) |tools| {
            if (tools == .array and tools.array.items.len > 0) {
                try w.writeAll("\"tools\":[{\"functionDeclarations\":[");
                var first = true;
                for (tools.array.items) |tool| {
                    if (tool != .object) continue;
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{");
                    if (tool.object.get("name")) |n| { try w.writeAll("\"name\":"); try std.json.Stringify.value(n, .{}, w); }
                    if (tool.object.get("description")) |d| { try w.writeAll(",\"description\":"); try std.json.Stringify.value(d, .{}, w); }
                    if (tool.object.get("input_schema")) |s| { try w.writeAll(",\"parameters\":"); try std.json.Stringify.value(s, .{}, w); }
                    try w.writeAll("}");
                }
                try w.writeAll("]}],");
            }
        }
    } else {
        // OpenAI tools -> Google functionDeclarations
        if (parsed.object.get("tools")) |tools| {
            if (tools == .array and tools.array.items.len > 0) {
                try w.writeAll("\"tools\":[{\"functionDeclarations\":[");
                var first = true;
                for (tools.array.items) |tool| {
                    if (tool != .object) continue;
                    const func = tool.object.get("function") orelse continue;
                    if (func != .object) continue;
                    if (!first) try w.writeAll(",");
                    first = false;
                    try w.writeAll("{");
                    if (func.object.get("name")) |n| { try w.writeAll("\"name\":"); try std.json.Stringify.value(n, .{}, w); }
                    if (func.object.get("description")) |d| { try w.writeAll(",\"description\":"); try std.json.Stringify.value(d, .{}, w); }
                    if (func.object.get("parameters")) |p| { try w.writeAll(",\"parameters\":"); try std.json.Stringify.value(p, .{}, w); }
                    try w.writeAll("}");
                }
                try w.writeAll("]}],");
            }
        }
    }

    try w.writeAll("\"contents\":[");

    if (parsed.object.get("messages")) |msgs| {
        if (msgs == .array) for (msgs.array.items, 0..) |msg, i| {
            if (msg != .object) continue;
            const role = switch (msg.object.get("role") orelse continue) { .string => |s| s, else => continue };
            const content = msg.object.get("content") orelse continue;
            if (i > 0) try w.writeAll(",");
            const gemini_role = if (std.mem.eql(u8, role, "assistant")) "model" else role;
            try w.print("{{\"parts\":[", .{});
            switch (content) {
                .string => |s| {
                    try w.writeAll("{\"text\":");
                    try std.json.Stringify.encodeJsonString(s, .{}, w);
                    try w.writeAll("}");
                },
                .array => {
                    for (content.array.items, 0..) |item, ci| {
                        if (ci > 0) try w.writeAll(",");
                        if (item == .object) {
                            const text_val = item.object.get("text") orelse continue;
                            if (text_val != .string) continue;
                            try w.writeAll("{\"text\":");
                            try std.json.Stringify.encodeJsonString(text_val.string, .{}, w);
                            try w.writeAll("}");
                        }
                    }
                },
                else => {},
            }
            try w.print("],\"role\":\"{s}\"}}", .{gemini_role});
        };
    }
    try w.writeAll("]");
}

fn buildXAIRequest(allocator: std.mem.Allocator, w: *std.io.Writer, parsed: std.json.Value, model: []const u8, is_anthropic: bool) !void {
    try w.print("\"model\":\"{s}\",\"stream\":true,", .{model});
    if (parsed.object.get("temperature")) |temp| {
        try w.writeAll("\"temperature\":"); try std.json.Stringify.value(temp, .{}, w); try w.writeAll(",");
    } else {
        try w.writeAll("\"temperature\":1.0,");
    }
    try w.writeAll("\"messages\":[");
    var wrote_any = false;
    if (is_anthropic) {
        if (extractSystemText(allocator, parsed)) |sys_text| {
            try w.writeAll("{\"role\":\"system\",\"content\":");
            try std.json.Stringify.encodeJsonString(sys_text, .{}, w);
            try w.writeAll("}");
            wrote_any = true;
        }
    }
    if (parsed.object.get("messages")) |msgs| {
        if (msgs == .array) for (msgs.array.items) |msg| {
            if (msg != .object) continue;
            const role = switch (msg.object.get("role") orelse continue) { .string => |s| s, else => continue };
            const content = msg.object.get("content") orelse continue;
            if (wrote_any) try w.writeAll(",");
            wrote_any = true;
            try w.print("{{\"role\":\"{s}\",\"content\":", .{role});
            switch (content) {
                .string => try std.json.Stringify.encodeJsonString(content.string, .{}, w),
                .array => {
                    var buf: std.io.Writer.Allocating = .init(allocator);
                    defer buf.deinit();
                    for (content.array.items) |item| {
                        if (item == .object) {
                            const text_val = item.object.get("text") orelse continue;
                            if (text_val == .string) buf.writer.writeAll(text_val.string) catch continue;
                        }
                    }
                    try std.json.Stringify.encodeJsonString(buf.written(), .{}, w);
                },
                else => try w.writeAll("\"\""),
            }
            try w.writeAll("}");
        };
    }
    try w.writeAll("]");
}

// ── Response conversion ──

pub const StreamContent = struct {
    thinking: ?[]const u8,
    text: []const u8,
    tool_calls: ?[]const u8, // JSON array of tool_use blocks
};

pub fn extractContentFromStream(allocator: std.mem.Allocator, response: []const u8) !StreamContent {
    var text_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer text_buf.deinit();
    var think_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer think_buf.deinit();
    var tool_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer tool_buf.deinit();

    // Track tool_use blocks being built from streaming events
    var current_tool_id: ?[]const u8 = null;
    var current_tool_name: ?[]const u8 = null;
    var tool_input_buf: std.io.Writer.Allocating = .init(allocator);
    defer tool_input_buf.deinit();
    var tool_count: usize = 0;

    var lines = std.mem.splitScalar(u8, response, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const p = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer p.deinit();

        const obj = if (p.value.object.get("event")) |event|
            (if (event == .object) event else p.value)
        else
            p.value;

        if (obj.object.get("type")) |et| {
            if (et == .string) {
                if (std.mem.eql(u8, et.string, "response.output_text.delta")) {
                    if (obj.object.get("delta")) |d| {
                        if (d == .string) try text_buf.writer.writeAll(d.string);
                    }
                    continue;
                }
                if (std.mem.eql(u8, et.string, "content_block_start")) {
                    const cb = obj.object.get("content_block") orelse continue;
                    if (cb != .object) continue;
                    const cb_type = switch (cb.object.get("type") orelse continue) { .string => |s| s, else => continue };
                    if (std.mem.eql(u8, cb_type, "tool_use")) {
                        if (cb.object.get("id")) |id| {
                            if (id == .string) {
                                if (current_tool_id) |old| allocator.free(old);
                                current_tool_id = allocator.dupe(u8, id.string) catch null;
                            }
                        }
                        if (cb.object.get("name")) |name| {
                            if (name == .string) {
                                if (current_tool_name) |old| allocator.free(old);
                                current_tool_name = allocator.dupe(u8, name.string) catch null;
                            }
                        }
                        tool_input_buf.deinit();
                        tool_input_buf = .init(allocator);
                    }
                    continue;
                }
                if (std.mem.eql(u8, et.string, "content_block_delta")) {
                    const delta = obj.object.get("delta") orelse continue;
                    if (delta != .object) continue;
                    const dt = switch (delta.object.get("type") orelse continue) { .string => |s| s, else => continue };
                    if (std.mem.eql(u8, dt, "text_delta")) {
                        if (delta.object.get("text")) |t| { if (t == .string) try text_buf.writer.writeAll(t.string); }
                    } else if (std.mem.eql(u8, dt, "thinking_delta")) {
                        if (delta.object.get("thinking")) |t| { if (t == .string) try think_buf.writer.writeAll(t.string); }
                    } else if (std.mem.eql(u8, dt, "input_json_delta")) {
                        if (delta.object.get("partial_json")) |pj| { if (pj == .string) try tool_input_buf.writer.writeAll(pj.string); }
                    }
                    continue;
                }
                if (std.mem.eql(u8, et.string, "content_block_stop")) {
                    // Finalize tool_use block if we were building one
                    if (current_tool_id != null and current_tool_name != null) {
                        const tw = &tool_buf.writer;
                        if (tool_count > 0) try tw.writeAll(",");
                        try tw.writeAll("{\"id\":");
                        try std.json.Stringify.encodeJsonString(current_tool_id.?, .{}, tw);
                        try tw.writeAll(",\"type\":\"function\",\"function\":{\"name\":");
                        try std.json.Stringify.encodeJsonString(current_tool_name.?, .{}, tw);
                        try tw.writeAll(",\"arguments\":");
                        const input_json = tool_input_buf.written();
                        if (input_json.len > 0) {
                            try std.json.Stringify.encodeJsonString(input_json, .{}, tw);
                        } else {
                            try tw.writeAll("\"{}\"");
                        }
                        try tw.writeAll("}}");
                        tool_count += 1;
                        allocator.free(current_tool_id.?);
                        current_tool_id = null;
                        allocator.free(current_tool_name.?);
                        current_tool_name = null;
                        tool_input_buf.deinit();
                        tool_input_buf = .init(allocator);
                    }
                    continue;
                }
            }
        }

        if (obj.object.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const choice = choices.array.items[0];
                if (choice == .object) {
                    if (choice.object.get("delta")) |delta| {
                        if (delta == .object) {
                            if (delta.object.get("content")) |c| {
                                if (c == .string) try text_buf.writer.writeAll(c.string);
                            }
                        }
                    }
                }
            }
            continue;
        }

        if (obj.object.get("candidates")) |candidates| {
            if (candidates == .array and candidates.array.items.len > 0) {
                const cand = candidates.array.items[0];
                if (cand == .object) {
                    if (cand.object.get("content")) |content| {
                        if (content == .object) {
                            if (content.object.get("parts")) |parts| {
                                if (parts == .array) for (parts.array.items) |part| {
                                    if (part == .object) {
                                        if (part.object.get("text")) |t| {
                                            if (t == .string) try text_buf.writer.writeAll(t.string);
                                        }
                                    }
                                };
                            }
                        }
                    }
                }
            }
            continue;
        }
    }

    // Cleanup any dangling tool state
    if (current_tool_id) |id| allocator.free(id);
    if (current_tool_name) |name| allocator.free(name);

    const text = try text_buf.toOwnedSlice();
    const think_written = think_buf.written();
    const tool_written = tool_buf.written();

    var thinking: ?[]const u8 = null;
    if (think_written.len > 0) {
        thinking = try allocator.dupe(u8, think_written);
    }
    think_buf.deinit();

    var tool_calls: ?[]const u8 = null;
    if (tool_written.len > 0) {
        // Wrap in array brackets
        const tc = try std.fmt.allocPrint(allocator, "[{s}]", .{tool_written});
        tool_calls = tc;
    }
    tool_buf.deinit();

    return .{ .thinking = thinking, .text = text, .tool_calls = tool_calls };
}

pub fn convertToOpenAI(allocator: std.mem.Allocator, response: []const u8, model: []const u8) ![]const u8 {
    const sc = try extractContentFromStream(allocator, response);
    defer allocator.free(sc.text);
    defer if (sc.thinking) |t| allocator.free(t);
    defer if (sc.tool_calls) |t| allocator.free(t);

    var result: std.io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();
    const w = &result.writer;

    try w.writeAll("{\"id\":\"chatcmpl-zed\",\"object\":\"chat.completion\",\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\"");
    if (sc.thinking) |thinking| {
        try w.writeAll(",\"thinking\":");
        try std.json.Stringify.encodeJsonString(thinking, .{}, w);
    }
    try w.writeAll(",\"content\":");
    if (sc.tool_calls != null and sc.text.len == 0) {
        try w.writeAll("null");
    } else {
        try std.json.Stringify.encodeJsonString(sc.text, .{}, w);
    }
    if (sc.tool_calls) |tc| {
        try w.writeAll(",\"tool_calls\":");
        try w.writeAll(tc);
    }
    const finish_reason = if (sc.tool_calls != null) "tool_calls" else "stop";
    try w.print("}},\"finish_reason\":\"{s}\"}}]}}", .{finish_reason});
    return try result.toOwnedSlice();
}

pub fn convertToAnthropic(allocator: std.mem.Allocator, response: []const u8, model: []const u8) ![]const u8 {
    const sc = try extractContentFromStream(allocator, response);
    defer allocator.free(sc.text);
    defer if (sc.thinking) |t| allocator.free(t);
    defer if (sc.tool_calls) |t| allocator.free(t);

    var result: std.io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();
    const w = &result.writer;

    try w.writeAll("{\"id\":\"msg_zed\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"content\":[");
    var wrote_any = false;
    if (sc.thinking) |thinking| {
        try w.writeAll("{\"type\":\"thinking\",\"thinking\":");
        try std.json.Stringify.encodeJsonString(thinking, .{}, w);
        try w.writeAll("}");
        wrote_any = true;
    }
    if (sc.text.len > 0) {
        if (wrote_any) try w.writeAll(",");
        try w.writeAll("{\"type\":\"text\",\"text\":");
        try std.json.Stringify.encodeJsonString(sc.text, .{}, w);
        try w.writeAll("}");
        wrote_any = true;
    }
    if (sc.tool_calls) |tc| {
        // Convert OpenAI-format tool_calls back to Anthropic tool_use blocks
        const parsed_tc = std.json.parseFromSlice(std.json.Value, allocator, tc, .{}) catch null;
        if (parsed_tc) |ptc| {
            defer ptc.deinit();
            if (ptc.value == .array) {
                for (ptc.value.array.items) |tool_call| {
                    if (tool_call != .object) continue;
                    if (wrote_any) try w.writeAll(",");
                    wrote_any = true;
                    try w.writeAll("{\"type\":\"tool_use\"");
                    if (tool_call.object.get("id")) |id| {
                        try w.writeAll(",\"id\":"); try std.json.Stringify.value(id, .{}, w);
                    }
                    if (tool_call.object.get("function")) |func| {
                        if (func == .object) {
                            if (func.object.get("name")) |n| {
                                try w.writeAll(",\"name\":"); try std.json.Stringify.value(n, .{}, w);
                            }
                            if (func.object.get("arguments")) |args| {
                                try w.writeAll(",\"input\":");
                                if (args == .string) {
                                    // Parse the JSON string into an object
                                    const parsed_args = std.json.parseFromSlice(std.json.Value, allocator, args.string, .{}) catch {
                                        try w.writeAll("{}");
                                        try w.writeAll("}");
                                        continue;
                                    };
                                    defer parsed_args.deinit();
                                    try std.json.Stringify.value(parsed_args.value, .{}, w);
                                } else {
                                    try std.json.Stringify.value(args, .{}, w);
                                }
                            } else {
                                try w.writeAll(",\"input\":{}");
                            }
                        }
                    }
                    try w.writeAll("}");
                }
            }
        }
    }
    if (!wrote_any) {
        try w.writeAll("{\"type\":\"text\",\"text\":\"\"}");
    }
    const stop_reason = if (sc.tool_calls != null) "tool_use" else "end_turn";
    try w.print("],\"stop_reason\":\"{s}\"}}", .{stop_reason});
    return try result.toOwnedSlice();
}
