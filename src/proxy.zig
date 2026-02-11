const std = @import("std");
const builtin = @import("builtin");

const SYSTEM_ID = "6b87ab66-af2c-49c7-b986-ef4c27c9e1fb";

// Global proxy config
var proxy_initialized: bool = false;
var proxy_host: ?[]const u8 = null;
var proxy_port: u16 = 0;

pub fn init(allocator: std.mem.Allocator) void {
    if (proxy_initialized) return;
    proxy_initialized = true;

    const env_names = [_][]const u8{ "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy" };
    for (env_names) |name| {
        const val = std.process.getEnvVarOwned(allocator, name) catch continue;
        if (val.len == 0) continue;
        if (parseProxyUrl(allocator, val)) return;
    }

    if (comptime builtin.os.tag == .windows) {
        readWindowsSystemProxy(allocator);
    }
}

pub fn getHost() ?[]const u8 {
    return proxy_host;
}

pub fn getPort() u16 {
    return proxy_port;
}

fn parseProxyUrl(allocator: std.mem.Allocator, val: []const u8) bool {
    const uri = std.Uri.parse(val) catch return false;
    const raw_host = uri.host orelse return false;
    const host = switch (raw_host) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    proxy_host = allocator.dupe(u8, host) catch return false;
    proxy_port = uri.port orelse 7890;
    std.debug.print("[zed] using HTTPS proxy: {s}:{d}\n", .{ proxy_host.?, proxy_port });
    return true;
}

fn readWindowsSystemProxy(allocator: std.mem.Allocator) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "reg", "query", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "/v", "ProxyEnable" },
        .max_output_bytes = 4096,
    }) catch return;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (std.mem.indexOf(u8, result.stdout, "0x1") == null) return;

    const result2 = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "reg", "query", "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", "/v", "ProxyServer" },
        .max_output_bytes = 4096,
    }) catch return;
    defer allocator.free(result2.stdout);
    defer allocator.free(result2.stderr);

    if (std.mem.indexOf(u8, result2.stdout, "ProxyServer")) |idx| {
        const after = result2.stdout[idx..];
        if (std.mem.indexOf(u8, after, "REG_SZ")) |sz_idx| {
            var val_start = sz_idx + "REG_SZ".len;
            while (val_start < after.len and (after[val_start] == ' ' or after[val_start] == '\t')) val_start += 1;
            var val_end = val_start;
            while (val_end < after.len and after[val_end] != '\r' and after[val_end] != '\n') val_end += 1;
            const proxy_val = std.mem.trim(u8, after[val_start..val_end], " \t");
            if (proxy_val.len > 0) {
                if (std.mem.indexOf(u8, proxy_val, ":")) |colon| {
                    proxy_host = allocator.dupe(u8, proxy_val[0..colon]) catch return;
                    proxy_port = std.fmt.parseInt(u16, proxy_val[colon + 1 ..], 10) catch 7890;
                } else {
                    proxy_host = allocator.dupe(u8, proxy_val) catch return;
                    proxy_port = 7890;
                }
                std.debug.print("[zed] using system proxy: {s}:{d}\n", .{ proxy_host.?, proxy_port });
            }
        }
    }
}

/// Send HTTP POST via proxy using curl subprocess
pub fn sendViaProxy(allocator: std.mem.Allocator, bearer: []const u8, body: []const u8) ![]const u8 {
    const p_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ proxy_host.?, proxy_port });
    defer allocator.free(p_url);

    const auth_header = try std.fmt.allocPrint(allocator, "authorization: {s}", .{bearer});
    defer allocator.free(auth_header);

    var tmp_name_buf: [64]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_name_buf, "zed2api_req_{d}.json", .{std.time.milliTimestamp()}) catch "zed2api_req_tmp.json";
    {
        const f = std.fs.cwd().createFile(tmp_path, .{}) catch return error.UpstreamError;
        defer f.close();
        f.writeAll(body) catch return error.UpstreamError;
    }
    defer std.fs.cwd().deleteFile(tmp_path) catch {};

    const at_path = try std.fmt.allocPrint(allocator, "@{s}", .{tmp_path});
    defer allocator.free(at_path);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl",           "-s",
            "-x",             p_url,
            "-X",             "POST",
            "https://cloud.zed.dev/completions",
            "-H",             auth_header,
            "-H",             "content-type: application/json",
            "-H",             "x-zed-version: 0.222.4+stable.147.b385025df963c9e8c3f74cc4dadb1c4b29b3c6f0",
            "--data-binary",  at_path,
            "--max-time",     "120",
            "-w",             "\n__HTTP_STATUS__%{http_code}",
        },
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch return error.UpstreamError;
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) {
        std.debug.print("[zed] curl failed: {s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.UpstreamError;
    }

    if (result.stdout.len == 0) {
        std.debug.print("[zed] proxy: empty response, stderr={s}\n", .{result.stderr});
        allocator.free(result.stdout);
        return error.UpstreamError;
    }

    var response_body = result.stdout;
    var http_status: []const u8 = "unknown";
    if (std.mem.lastIndexOf(u8, result.stdout, "\n__HTTP_STATUS__")) |pos| {
        response_body = result.stdout[0..pos];
        http_status = result.stdout[pos + "\n__HTTP_STATUS__".len ..];
    }

    if (response_body.len == 0) {
        std.debug.print("[zed] proxy: empty body with status {s}\n", .{http_status});
        allocator.free(result.stdout);
        return error.UpstreamError;
    }

    if (std.mem.startsWith(u8, response_body, "<html>") or std.mem.startsWith(u8, response_body, "<!DOCTYPE")) {
        std.debug.print("[zed] proxy: HTML error response (status={s})\n", .{http_status});
        allocator.free(result.stdout);
        return error.UpstreamError;
    }

    if (std.mem.startsWith(u8, response_body, "{\"error\"") or std.mem.startsWith(u8, response_body, "{\"detail\"")) {
        std.debug.print("[zed] upstream error (status={s}): {s}\n", .{ http_status, response_body[0..@min(response_body.len, 500)] });
        allocator.free(result.stdout);
        return error.UpstreamError;
    }

    const owned = allocator.dupe(u8, response_body) catch {
        allocator.free(result.stdout);
        return error.UpstreamError;
    };
    allocator.free(result.stdout);
    return owned;
}

/// Send HTTP POST to Zed with retry logic
pub fn sendToZed(allocator: std.mem.Allocator, jwt: []const u8, body: []const u8) ![]const u8 {
    const bearer = try std.fmt.allocPrint(allocator, "Bearer {s}", .{jwt});
    defer allocator.free(bearer);

    init(allocator);

    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const result = if (proxy_host != null) blk: {
            break :blk sendViaProxy(allocator, bearer, body);
        } else blk: {
            var response_buf: std.io.Writer.Allocating = .init(allocator);
            errdefer response_buf.deinit();

            var client: std.http.Client = .{ .allocator = allocator };
            defer client.deinit();

            const fetch_result = client.fetch(.{
                .location = .{ .url = "https://cloud.zed.dev/completions" },
                .method = .POST,
                .payload = body,
                .response_writer = &response_buf.writer,
                .extra_headers = &.{
                    .{ .name = "authorization", .value = bearer },
                    .{ .name = "content-type", .value = "application/json" },
                    .{ .name = "x-zed-version", .value = "0.222.4+stable.147.b385025df963c9e8c3f74cc4dadb1c4b29b3c6f0" },
                },
            }) catch |err| {
                std.debug.print("[zed] network error attempt {d}: {}\n", .{ attempt + 1, err });
                response_buf.deinit();
                break :blk @as(anyerror![]const u8, error.UpstreamError);
            };

            if (fetch_result.status == .ok) {
                break :blk @as(anyerror![]const u8, response_buf.toOwnedSlice() catch {
                    response_buf.deinit();
                    break :blk @as(anyerror![]const u8, error.UpstreamError);
                });
            }

            const err_body = response_buf.written();
            std.debug.print("[zed] upstream {d} attempt {d}: {s}\n", .{ @intFromEnum(fetch_result.status), attempt + 1, err_body });
            response_buf.deinit();

            if (fetch_result.status == .unauthorized or fetch_result.status == .forbidden) {
                break :blk @as(anyerror![]const u8, error.TokenExpired);
            }
            if (fetch_result.status == .too_many_requests) {
                break :blk @as(anyerror![]const u8, error.RateLimited);
            }
            break :blk @as(anyerror![]const u8, error.UpstreamError);
        };

        if (result) |data| {
            return data;
        } else |err| {
            std.debug.print("[zed] attempt {d} error: {}\n", .{ attempt + 1, err });
            if (err == error.TokenExpired) return error.TokenExpired;
            if (err == error.RateLimited) {
                if (attempt < 2) std.Thread.sleep(3_000_000_000);
                continue;
            }
            if (attempt < 2) std.Thread.sleep(1_000_000_000 * (@as(u64, 1) << @intCast(attempt)));
        }
    }
    return error.UpstreamError;
}
