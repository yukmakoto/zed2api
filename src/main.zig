const std = @import("std");
const server = @import("server.zig");
const accounts = @import("accounts.zig");
const auth = @import("auth.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const cmd = args.next() orelse "serve";

    if (std.mem.eql(u8, cmd, "serve")) {
        const port_str = args.next() orelse "8000";
        const port = std.fmt.parseInt(u16, port_str, 10) catch 8000;
        try server.run(allocator, port);
    } else if (std.mem.eql(u8, cmd, "login")) {
        const name = args.next();
        try doLogin(allocator, name);
    } else if (std.mem.eql(u8, cmd, "accounts")) {
        try listAccounts(allocator);
    } else {
        printUsage();
    }
}

fn printUsage() void {
    std.debug.print(
        \\zed2api - Zed LLM API Proxy
        \\
        \\Usage:
        \\  zed2api serve [port]    Start API server (default: 8000)
        \\  zed2api login [name]    Login via GitHub OAuth
        \\  zed2api accounts        List configured accounts
        \\
        \\Endpoints:
        \\  POST /v1/chat/completions   OpenAI compatible
        \\  POST /v1/messages           Anthropic native
        \\  GET  /v1/models             List models
        \\  GET  /zed/accounts          List accounts
        \\  POST /zed/login             Start OAuth login
        \\  GET  /                      Web UI
        \\
    , .{});
}

fn doLogin(allocator: std.mem.Allocator, name: ?[]const u8) !void {
    const creds = try auth.login(allocator);
    defer allocator.free(creds.user_id);
    defer allocator.free(creds.access_token);

    std.debug.print("\n[ok] user_id: {s}\n", .{creds.user_id});

    const account_name = name orelse creds.user_id;
    try accounts.addAccount(allocator, account_name, creds.user_id, creds.access_token);
    std.debug.print("[ok] saved to accounts.json as '{s}'\n", .{account_name});
}

fn listAccounts(allocator: std.mem.Allocator) !void {
    var mgr = accounts.AccountManager.init(allocator);
    defer mgr.deinit();
    mgr.loadFromFile() catch {};

    if (mgr.list.items.len == 0) {
        std.debug.print("No accounts. Run: zed2api login\n", .{});
        return;
    }
    for (mgr.list.items) |acc| {
        std.debug.print("  {s} (uid: {s})\n", .{ acc.name, acc.user_id });
    }
}
