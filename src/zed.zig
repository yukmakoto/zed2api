const std = @import("std");
const accounts = @import("accounts.zig");
const proxy = @import("proxy.zig");
const providers = @import("providers.zig");

const SYSTEM_ID = "6b87ab66-af2c-49c7-b986-ef4c27c9e1fb";

// Re-export for server.zig
pub const initProxyPublic = proxy.init;
pub const getProxyHost = proxy.getHost;
pub const getProxyPort = proxy.getPort;
pub const buildZedPayload = providers.buildZedPayload;
pub const extractModelFromBody = providers.extractModelFromBody;

// ── Token management ──

pub fn getToken(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    if (acc.jwt_token) |tok| {
        if (std.time.timestamp() < acc.jwt_exp - 60) return tok;
        allocator.free(tok);
        acc.jwt_token = null;
    }
    return fetchNewToken(allocator, acc);
}

fn fetchNewToken(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    const auth_header = try std.fmt.allocPrint(allocator, "{s} {s}", .{ acc.user_id, acc.credential_json });
    defer allocator.free(auth_header);

    var response_buf: std.io.Writer.Allocating = .init(allocator);
    defer response_buf.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const result = client.fetch(.{
        .location = .{ .url = "https://cloud.zed.dev/client/llm_tokens" },
        .method = .POST,
        .payload = "",
        .response_writer = &response_buf.writer,
        .extra_headers = &.{
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "x-zed-system-id", .value = SYSTEM_ID },
        },
    }) catch |err| {
        std.debug.print("[zed] token fetch error: {}\n", .{err});
        return error.TokenRefreshFailed;
    };

    if (result.status != .ok) {
        std.debug.print("[zed] token fetch status: {d} body: {s}\n", .{ @intFromEnum(result.status), response_buf.written() });
        return error.TokenRefreshFailed;
    }

    const body = response_buf.written();
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.TokenRefreshFailed;
    defer parsed.deinit();

    const token = switch (parsed.value.object.get("token") orelse return error.NoToken) {
        .string => |s| allocator.dupe(u8, s) catch return error.TokenRefreshFailed,
        else => return error.InvalidToken,
    };

    acc.jwt_exp = parseJwtExp(token) catch 0;
    acc.jwt_token = token;
    std.debug.print("[zed] token refreshed for uid {s}\n", .{acc.user_id});
    return token;
}

fn parseJwtExp(jwt: []const u8) !i64 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next();
    const payload_b64 = parts.next() orelse return error.InvalidJwt;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return error.InvalidJwt;
    var decoded: [4096]u8 = undefined;
    decoder.decode(decoded[0..decoded_len], payload_b64) catch return error.InvalidJwt;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, decoded[0..decoded_len], .{});
    defer parsed.deinit();
    return switch (parsed.value.object.get("exp") orelse return error.NoExp) {
        .integer => |i| i,
        else => error.InvalidExp,
    };
}

pub fn parseJwtClaims(allocator: std.mem.Allocator, jwt: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, jwt, '.');
    _ = parts.next();
    const payload_b64 = parts.next() orelse return error.InvalidJwt;
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = decoder.calcSizeForSlice(payload_b64) catch return error.InvalidJwt;
    const decoded = try allocator.alloc(u8, decoded_len);
    decoder.decode(decoded, payload_b64) catch {
        allocator.free(decoded);
        return error.InvalidJwt;
    };
    return decoded;
}

// ── Proxy endpoints (non-streaming) ──

pub fn proxyChatCompletions(allocator: std.mem.Allocator, acc: *accounts.Account, body: []const u8) ![]const u8 {
    return proxyChatCompletionsInner(allocator, acc, body) catch |err| {
        if (err == error.TokenExpired) {
            if (acc.jwt_token) |tok| { allocator.free(tok); acc.jwt_token = null; }
            std.debug.print("[zed] token expired, refreshing and retrying...\n", .{});
            return proxyChatCompletionsInner(allocator, acc, body);
        }
        return err;
    };
}

fn proxyChatCompletionsInner(allocator: std.mem.Allocator, acc: *accounts.Account, body: []const u8) ![]const u8 {
    const jwt = try getToken(allocator, acc);
    const model_name = providers.extractModelFromBody(allocator, body) catch "unknown";
    const model = providers.normalizeModelName(model_name);

    const payload = try providers.buildZedPayload(allocator, body, false);
    defer allocator.free(payload);

    const response = try proxy.sendToZed(allocator, jwt, payload);
    defer allocator.free(response);
    return try providers.convertToOpenAI(allocator, response, model);
}

pub fn proxyMessages(allocator: std.mem.Allocator, acc: *accounts.Account, body: []const u8) ![]const u8 {
    return proxyMessagesInner(allocator, acc, body) catch |err| {
        if (err == error.TokenExpired) {
            if (acc.jwt_token) |tok| { allocator.free(tok); acc.jwt_token = null; }
            std.debug.print("[zed] token expired, refreshing and retrying...\n", .{});
            return proxyMessagesInner(allocator, acc, body);
        }
        return err;
    };
}

fn proxyMessagesInner(allocator: std.mem.Allocator, acc: *accounts.Account, body: []const u8) ![]const u8 {
    const jwt = try getToken(allocator, acc);
    const model_name = providers.extractModelFromBody(allocator, body) catch "unknown";
    const model = providers.normalizeModelName(model_name);

    const payload = try providers.buildZedPayload(allocator, body, true);
    defer allocator.free(payload);

    const response = try proxy.sendToZed(allocator, jwt, payload);
    defer allocator.free(response);
    return try providers.convertToAnthropic(allocator, response, model);
}

pub fn fetchBillingUsage(allocator: std.mem.Allocator, acc: *accounts.Account) ![]const u8 {
    const auth_header = try std.fmt.allocPrint(allocator, "{s} {s}", .{ acc.user_id, acc.credential_json });
    defer allocator.free(auth_header);

    var response_buf: std.io.Writer.Allocating = .init(allocator);
    errdefer response_buf.deinit();

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = "https://cloud.zed.dev/client/users/me" },
        .method = .GET,
        .response_writer = &response_buf.writer,
        .extra_headers = &.{
            .{ .name = "authorization", .value = auth_header },
            .{ .name = "accept", .value = "application/json" },
            .{ .name = "content-type", .value = "application/json" },
        },
    });

    if (result.status != .ok) {
        const err_body = response_buf.written();
        std.debug.print("[zed] users/me failed {}: {s}\n", .{ result.status, err_body });
        response_buf.deinit();
        return error.BillingFetchFailed;
    }
    return try response_buf.toOwnedSlice();
}
