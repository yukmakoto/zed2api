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
    try w.writeAll("\"messages\":[");
    if (parsed.object.get("messages")) |msgs| {
        if (msgs == .array) for (msgs.array.items, 0..) |msg, i| {
            if (i > 0) try w.writeAll(",");
            try writeMessage(w, msg);
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
};

pub fn extractContentFromStream(allocator: std.mem.Allocator, response: []const u8) !StreamContent {
    var text_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer text_buf.deinit();
    var think_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer think_buf.deinit();

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
                if (std.mem.eql(u8, et.string, "content_block_delta")) {
                    const delta = obj.object.get("delta") orelse continue;
                    if (delta != .object) continue;
                    const dt = switch (delta.object.get("type") orelse continue) { .string => |s| s, else => continue };
                    if (std.mem.eql(u8, dt, "text_delta")) {
                        if (delta.object.get("text")) |t| { if (t == .string) try text_buf.writer.writeAll(t.string); }
                    } else if (std.mem.eql(u8, dt, "thinking_delta")) {
                        if (delta.object.get("thinking")) |t| { if (t == .string) try think_buf.writer.writeAll(t.string); }
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

    const text = try text_buf.toOwnedSlice();
    const think_written = think_buf.written();
    if (think_written.len > 0) {
        const thinking = try allocator.dupe(u8, think_written);
        think_buf.deinit();
        return .{ .thinking = thinking, .text = text };
    }
    think_buf.deinit();
    return .{ .thinking = null, .text = text };
}

pub fn convertToOpenAI(allocator: std.mem.Allocator, response: []const u8, model: []const u8) ![]const u8 {
    const sc = try extractContentFromStream(allocator, response);
    defer allocator.free(sc.text);
    defer if (sc.thinking) |t| allocator.free(t);

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
    try std.json.Stringify.encodeJsonString(sc.text, .{}, w);
    try w.writeAll("},\"finish_reason\":\"stop\"}]}");
    return try result.toOwnedSlice();
}

pub fn convertToAnthropic(allocator: std.mem.Allocator, response: []const u8, model: []const u8) ![]const u8 {
    const sc = try extractContentFromStream(allocator, response);
    defer allocator.free(sc.text);
    defer if (sc.thinking) |t| allocator.free(t);

    var result: std.io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();
    const w = &result.writer;

    try w.writeAll("{\"id\":\"msg_zed\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"");
    try w.writeAll(model);
    try w.writeAll("\",\"content\":[");
    if (sc.thinking) |thinking| {
        try w.writeAll("{\"type\":\"thinking\",\"thinking\":");
        try std.json.Stringify.encodeJsonString(thinking, .{}, w);
        try w.writeAll("},");
    }
    try w.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.encodeJsonString(sc.text, .{}, w);
    try w.writeAll("}]}");
    return try result.toOwnedSlice();
}
