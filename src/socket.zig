const std = @import("std");
const builtin = @import("builtin");

pub fn recv(stream: std.net.Stream, buf: []u8) !usize {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        const rc = ws2.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
        if (rc == ws2.SOCKET_ERROR) {
            const err = ws2.WSAGetLastError();
            return switch (err) {
                ws2.WinsockError.WSAECONNRESET => error.ConnectionResetByPeer,
                ws2.WinsockError.WSAECONNABORTED => error.BrokenPipe,
                else => error.Unexpected,
            };
        }
        if (rc == 0) return 0;
        return @intCast(rc);
    } else {
        return stream.read(buf);
    }
}

pub fn send(stream: std.net.Stream, data: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        const ws2 = std.os.windows.ws2_32;
        var sent: usize = 0;
        while (sent < data.len) {
            const rc = ws2.send(stream.handle, data[sent..].ptr, @intCast(data.len - sent), 0);
            if (rc == ws2.SOCKET_ERROR) {
                const err = ws2.WSAGetLastError();
                return switch (err) {
                    ws2.WinsockError.WSAECONNRESET => error.ConnectionResetByPeer,
                    ws2.WinsockError.WSAECONNABORTED => error.BrokenPipe,
                    else => error.Unexpected,
                };
            }
            sent += @intCast(rc);
        }
    } else {
        _ = try stream.write(data);
    }
}

pub fn writeResponse(stream: std.net.Stream, status: u16, body: []const u8) void {
    writeResponseWithType(stream, status, body, "application/json");
}

pub fn writeResponseWithType(stream: std.net.Stream, status: u16, body: []const u8, content_type: []const u8) void {
    const status_text = switch (status) {
        200 => "OK", 400 => "Bad Request", 404 => "Not Found",
        500 => "Internal Server Error", 502 => "Bad Gateway", else => "Unknown",
    };
    var header_buf: [1024]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nConnection: close\r\n\r\n", .{ status, status_text, content_type, body.len }) catch return;
    send(stream, header) catch {};
    send(stream, body) catch {};
}
