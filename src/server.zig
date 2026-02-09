const std = @import("std");
const accounts = @import("accounts.zig");
const auth = @import("auth.zig");
const zed = @import("zed.zig");
const proxy = @import("proxy.zig");
const providers = @import("providers.zig");
const stream = @import("stream.zig");
const socket = @import("socket.zig");
const web_ui = @embedFile("web_index_html");

var account_mgr: accounts.AccountManager = undefined;
var global_allocator: std.mem.Allocator = undefined;

pub fn run(allocator: std.mem.Allocator, port: u16) !void {
    global_allocator = allocator;
    account_mgr = accounts.AccountManager.init(allocator);
    defer account_mgr.deinit();
    account_mgr.loadFromFile() catch {};

    std.debug.print("[zed2api] http://127.0.0.1:{d}\n[zed2api] {d} account(s) loaded\n", .{ port, account_mgr.list.items.len });

    proxy.init(allocator);
    if (proxy.getHost()) |host| {
        std.debug.print("[zed2api] proxy: {s}:{d}\n", .{ host, proxy.getPort() });
    } else {
        std.debug.print("[zed2api] proxy: none (set HTTPS_PROXY to use)\n", .{});
    }

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);
    var tcp_server = try addr.listen(.{ .reuse_address = true });
    defer tcp_server.deinit();

    while (true) {
        const conn = tcp_server.accept() catch continue;
        const thread = std.Thread.spawn(.{}, handleConnection, .{conn.stream}) catch {
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(conn_stream: std.net.Stream) void {
    defer conn_stream.close();

    var hdr_buf: [8192]u8 = undefined;
    var hdr_total: usize = 0;

    while (hdr_total < hdr_buf.len) {
        const n = socket.recv(conn_stream, hdr_buf[hdr_total..]) catch return;
        if (n == 0) return;
        hdr_total += n;
        if (std.mem.indexOf(u8, hdr_buf[0..hdr_total], "\r\n\r\n") != null) break;
    }

    const header_end = std.mem.indexOf(u8, hdr_buf[0..hdr_total], "\r\n\r\n") orelse return;
    const headers = hdr_buf[0..header_end];
    const body_in_hdr = hdr_buf[header_end + 4 .. hdr_total];

    const first_line_end = std.mem.indexOf(u8, headers, "\r\n") orelse return;
    const first_line = headers[0..first_line_end];
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    const method = parts.next() orelse return;
    const full_path = parts.next() orelse return;
    const path = if (std.mem.indexOf(u8, full_path, "?")) |i| full_path[0..i] else full_path;

    var content_length: usize = 0;
    var header_lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (header_lines.next()) |line| {
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const val = std.mem.trim(u8, line["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }

    // Read body (up to 16MB)
    const max_body = 16 * 1024 * 1024;
    const actual_len = @min(content_length, max_body);
    var body: []const u8 = "";
    var body_alloc: ?[]u8 = null;
    defer if (body_alloc) |b| global_allocator.free(b);

    if (actual_len > 0) {
        const body_buf = global_allocator.alloc(u8, actual_len) catch {
            socket.writeResponse(conn_stream, 500, "{\"error\":\"body too large\"}");
            return;
        };
        body_alloc = body_buf;
        const already = @min(body_in_hdr.len, actual_len);
        @memcpy(body_buf[0..already], body_in_hdr[0..already]);
        var filled: usize = already;
        while (filled < actual_len) {
            const n = socket.recv(conn_stream, body_buf[filled..actual_len]) catch break;
            if (n == 0) break;
            filled += n;
        }
        body = body_buf[0..filled];
    }

    // Streaming proxy check
    const is_messages = std.mem.eql(u8, path, "/v1/messages") and std.mem.eql(u8, method, "POST");
    const is_completions = std.mem.eql(u8, path, "/v1/chat/completions") and std.mem.eql(u8, method, "POST");
    const wants_stream = (is_messages or is_completions) and
        (std.mem.indexOf(u8, body, "\"stream\":true") != null or
        std.mem.indexOf(u8, body, "\"stream\": true") != null);

    if (wants_stream) {
        const req_model = providers.extractModelFromBody(global_allocator, body) catch "unknown";
        const has_thinking = std.mem.indexOf(u8, body, "\"thinking\"") != null;
        std.debug.print("[req] {s} {s} model={s} thinking={} body={d}bytes (stream)\n", .{ method, path, req_model, has_thinking, body.len });
        stream.handleStreamProxy(conn_stream, body, is_messages, &account_mgr, global_allocator);
        return;
    }

    // Non-streaming route
    const response = route(method, path, body) catch |err| {
        std.debug.print("[zed2api] route error: {} for {s} {s}\n", .{ err, method, path });
        socket.writeResponse(conn_stream, 500, "{\"error\":\"internal error\"}");
        return;
    };
    defer if (response.allocated) global_allocator.free(response.body);
    socket.writeResponseWithType(conn_stream, response.status, response.body, response.content_type);
}

const Response = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "application/json",
    allocated: bool = false,
};

fn route(method: []const u8, path: []const u8, body: []const u8) !Response {
    std.debug.print("[req] {s} {s} body={d}bytes\n", .{ method, path, body.len });

    if (std.mem.eql(u8, path, "/")) return .{ .status = 200, .body = web_ui, .content_type = "text/html; charset=utf-8" };
    if (std.mem.eql(u8, path, "/v1/models") and std.mem.eql(u8, method, "GET"))
        return .{ .status = 200, .body = @embedFile("models.json") };
    if (std.mem.eql(u8, path, "/api/event_logging/batch"))
        return .{ .status = 200, .body = "{\"status\":\"ok\"}" };
    if (std.mem.startsWith(u8, path, "/v1/messages/count_tokens"))
        return .{ .status = 200, .body = "{\"input_tokens\":0}" };
    if (std.mem.eql(u8, path, "/zed/accounts") and std.mem.eql(u8, method, "GET"))
        return try handleListAccounts();
    if (std.mem.eql(u8, path, "/zed/accounts/switch") and std.mem.eql(u8, method, "POST"))
        return handleSwitchAccount(body);
    if (std.mem.eql(u8, path, "/zed/usage") and std.mem.eql(u8, method, "GET"))
        return try handleUsage();
    if (std.mem.eql(u8, path, "/zed/billing") and std.mem.eql(u8, method, "GET"))
        return try handleBilling();
    if (std.mem.eql(u8, path, "/v1/chat/completions") and std.mem.eql(u8, method, "POST"))
        return try handleProxy(body, false);
    if (std.mem.eql(u8, path, "/v1/messages") and std.mem.eql(u8, method, "POST"))
        return try handleProxy(body, true);
    if (std.mem.eql(u8, path, "/zed/login") and std.mem.eql(u8, method, "POST"))
        return try handleLogin(body);
    if (std.mem.eql(u8, path, "/zed/login/status") and std.mem.eql(u8, method, "GET"))
        return handleLoginStatus();
    if (std.mem.eql(u8, method, "OPTIONS"))
        return .{ .status = 200, .body = "" };
    return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}

// ── Non-streaming proxy with failover ──

fn handleProxy(body: []const u8, is_anthropic: bool) !Response {
    if (account_mgr.list.items.len == 0) return .{ .status = 400, .body = "{\"error\":\"no account configured\"}" };

    const total = account_mgr.list.items.len;
    var try_order: [64]usize = undefined;
    const count = @min(total, 64);
    try_order[0] = account_mgr.current;
    var order_idx: usize = 1;
    for (0..total) |i| {
        if (i != account_mgr.current and order_idx < count) {
            try_order[order_idx] = i;
            order_idx += 1;
        }
    }

    var last_err: anyerror = error.UpstreamError;
    for (try_order[0..count]) |acc_idx| {
        const acc = &account_mgr.list.items[acc_idx];
        const result = if (is_anthropic)
            zed.proxyMessages(global_allocator, acc, body)
        else
            zed.proxyChatCompletions(global_allocator, acc, body);

        if (result) |data| {
            if (acc_idx != account_mgr.current) {
                std.debug.print("[zed2api] failover success: switched to '{s}'\n", .{acc.name});
                account_mgr.current = acc_idx;
            }
            return .{ .status = 200, .body = data, .allocated = true };
        } else |err| {
            last_err = err;
            std.debug.print("[zed2api] account '{s}' failed: {}\n", .{ acc.name, err });
            const should_failover = (err == error.TokenRefreshFailed or err == error.TokenExpired or err == error.UpstreamError);
            if (!should_failover) break;
        }
    }

    const status: u16 = switch (last_err) {
        error.TokenRefreshFailed => 401,
        error.TokenExpired => 401,
        error.UpstreamError => 502,
        else => 500,
    };
    const msg = switch (last_err) {
        error.TokenRefreshFailed => "{\"error\":{\"message\":\"All accounts failed: token refresh failed\",\"type\":\"auth_error\"}}",
        error.TokenExpired => "{\"error\":{\"message\":\"All accounts failed: token expired\",\"type\":\"auth_error\"}}",
        error.UpstreamError => "{\"error\":{\"message\":\"All accounts failed: upstream error\",\"type\":\"upstream_error\"}}",
        else => "{\"error\":{\"message\":\"All accounts failed: internal error\",\"type\":\"server_error\"}}",
    };
    return .{ .status = status, .body = msg };
}

// ── Account handlers ──

fn handleListAccounts() !Response {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(global_allocator);
    try w.writeAll("{\"accounts\":[");
    for (account_mgr.list.items, 0..) |acc, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"user_id\":\"{s}\",\"current\":{s}}}", .{
            acc.name, acc.user_id,
            if (i == account_mgr.current) "true" else "false",
        });
    }
    try w.print("],\"current\":\"{s}\"}}", .{
        if (account_mgr.getCurrent()) |c| c.name else "",
    });
    return .{ .status = 200, .body = try buf.toOwnedSlice(global_allocator), .allocated = true };
}

fn handleSwitchAccount(body: []const u8) Response {
    const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch
        return .{ .status = 400, .body = "{\"error\":\"invalid json\"}" };
    defer parsed.deinit();
    const name = switch (parsed.value.object.get("account") orelse return .{ .status = 400, .body = "{\"error\":\"missing account\"}" }) {
        .string => |s| s,
        else => return .{ .status = 400, .body = "{\"error\":\"bad type\"}" },
    };
    if (account_mgr.switchTo(name))
        return .{ .status = 200, .body = "{\"success\":true}" }
    else
        return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
}

fn handleUsage() !Response {
    const acc = account_mgr.getCurrent() orelse return .{ .status = 400, .body = "{\"error\":\"no account\"}" };
    const jwt = try zed.getToken(global_allocator, acc);
    const claims = try zed.parseJwtClaims(global_allocator, jwt);
    return .{ .status = 200, .body = claims, .allocated = true };
}

fn handleBilling() !Response {
    const acc = account_mgr.getCurrent() orelse return .{ .status = 400, .body = "{\"error\":\"no account\"}" };
    const user_info = zed.fetchBillingUsage(global_allocator, acc) catch {
        return .{ .status = 502, .body = "{\"error\":\"failed to fetch user info\"}" };
    };
    return .{ .status = 200, .body = user_info, .allocated = true };
}

// ── Login ──
var login_status: enum { idle, waiting, success, failed } = .idle;
var login_error_msg: []const u8 = "";
var login_result_name: []const u8 = "";

fn handleLogin(body: []const u8) !Response {
    if (login_status == .waiting) return .{ .status = 409, .body = "{\"error\":\"login already in progress\"}" };

    var account_name: []const u8 = "";
    if (body.len > 0) {
        const parsed = std.json.parseFromSlice(std.json.Value, global_allocator, body, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("name")) |n| {
                if (n == .string) account_name = global_allocator.dupe(u8, n.string) catch "";
            }
        }
    }

    const keypair = try global_allocator.create(auth.RsaKeyPair);
    keypair.* = auth.RsaKeyPair.generate(global_allocator) catch |err| {
        global_allocator.destroy(keypair);
        return err;
    };
    const pub_key = keypair.exportPublicKeyB64(global_allocator) catch |err| {
        keypair.deinit();
        global_allocator.destroy(keypair);
        return err;
    };

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    const tcp = try global_allocator.create(std.net.Server);
    tcp.* = addr.listen(.{}) catch |err| {
        global_allocator.free(pub_key);
        keypair.deinit();
        global_allocator.destroy(keypair);
        global_allocator.destroy(tcp);
        return err;
    };
    const port = tcp.listen_address.getPort();
    const url = try std.fmt.allocPrint(global_allocator, "https://zed.dev/native_app_signin?native_app_port={d}&native_app_public_key={s}", .{ port, pub_key });

    login_status = .waiting;
    const thread = std.Thread.spawn(.{}, loginWorker, .{ keypair, tcp, pub_key, account_name }) catch {
        login_status = .failed;
        tcp.deinit(); global_allocator.destroy(tcp);
        keypair.deinit(); global_allocator.destroy(keypair);
        global_allocator.free(pub_key); global_allocator.free(url);
        return .{ .status = 500, .body = "{\"error\":\"thread spawn failed\"}" };
    };
    thread.detach();
    auth.openBrowserPublic(url);

    var resp_buf: [4096]u8 = undefined;
    const resp = try std.fmt.bufPrint(&resp_buf, "{{\"login_url\":\"{s}\",\"port\":{d}}}", .{ url, port });
    const result = try global_allocator.dupe(u8, resp);
    global_allocator.free(url);
    return .{ .status = 200, .body = result, .allocated = true };
}

fn loginWorker(keypair: *auth.RsaKeyPair, tcp: *std.net.Server, pub_key: []const u8, account_name: []const u8) void {
    defer {
        tcp.deinit(); global_allocator.destroy(tcp);
        keypair.deinit(); global_allocator.destroy(keypair);
        global_allocator.free(pub_key);
        if (account_name.len > 0) global_allocator.free(account_name);
    }
    const creds = auth.loginWithServer(global_allocator, keypair, tcp) catch |err| {
        login_status = .failed;
        login_error_msg = @errorName(err);
        return;
    };
    defer global_allocator.free(creds.user_id);
    defer global_allocator.free(creds.access_token);

    const name = if (account_name.len > 0) account_name else creds.user_id;
    accounts.addAccount(global_allocator, name, creds.user_id, creds.access_token) catch |err| {
        login_status = .failed;
        login_error_msg = @errorName(err);
        return;
    };
    account_mgr.deinit();
    account_mgr = accounts.AccountManager.init(global_allocator);
    account_mgr.loadFromFile() catch {};
    login_result_name = global_allocator.dupe(u8, name) catch "";
    login_status = .success;
    std.debug.print("[login] success: {s}\n", .{name});
}

fn handleLoginStatus() Response {
    return switch (login_status) {
        .idle => .{ .status = 200, .body = "{\"status\":\"idle\"}" },
        .waiting => .{ .status = 200, .body = "{\"status\":\"waiting\"}" },
        .success => blk: { login_status = .idle; break :blk .{ .status = 200, .body = "{\"status\":\"success\"}" }; },
        .failed => blk: { login_status = .idle; break :blk .{ .status = 200, .body = "{\"status\":\"failed\"}" }; },
    };
}
