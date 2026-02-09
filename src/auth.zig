const std = @import("std");
const builtin = @import("builtin");

pub const Credentials = struct {
    user_id: []const u8,
    access_token: []const u8,
};

// ── Platform constants ──
const is_windows = builtin.os.tag == .windows;

// ── Windows BCrypt API ──
const BCRYPT_ALG_HANDLE = *anyopaque;
const BCRYPT_KEY_HANDLE = *anyopaque;
const NTSTATUS = i32;
const ULONG = u32;
const PUCHAR = [*]u8;

extern "bcrypt" fn BCryptOpenAlgorithmProvider(phAlgorithm: *BCRYPT_ALG_HANDLE, pszAlgId: [*:0]const u16, pszImplementation: ?*anyopaque, dwFlags: ULONG) callconv(.c) NTSTATUS;
extern "bcrypt" fn BCryptCloseAlgorithmProvider(hAlgorithm: BCRYPT_ALG_HANDLE, dwFlags: ULONG) callconv(.c) NTSTATUS;
extern "bcrypt" fn BCryptGenerateKeyPair(hAlgorithm: BCRYPT_ALG_HANDLE, phKey: *BCRYPT_KEY_HANDLE, dwLength: ULONG, dwFlags: ULONG) callconv(.c) NTSTATUS;
extern "bcrypt" fn BCryptFinalizeKeyPair(hKey: BCRYPT_KEY_HANDLE, dwFlags: ULONG) callconv(.c) NTSTATUS;
extern "bcrypt" fn BCryptExportKey(hKey: BCRYPT_KEY_HANDLE, hExportKey: ?BCRYPT_KEY_HANDLE, pszBlobType: [*:0]const u16, pbOutput: ?PUCHAR, cbOutput: ULONG, pcbResult: *ULONG, dwFlags: ULONG) callconv(.c) NTSTATUS;
extern "bcrypt" fn BCryptDecrypt(hKey: BCRYPT_KEY_HANDLE, pbInput: [*]const u8, cbInput: ULONG, pPaddingInfo: ?*anyopaque, pbIV: ?*anyopaque, cbIV: ULONG, pbOutput: ?PUCHAR, cbOutput: ULONG, pcbResult: *ULONG, dwFlags: ULONG) callconv(.c) NTSTATUS;
extern "bcrypt" fn BCryptDestroyKey(hKey: BCRYPT_KEY_HANDLE) callconv(.c) NTSTATUS;

const BCRYPT_RSAPUBLIC_BLOB_W = std.unicode.utf8ToUtf16LeStringLiteral("RSAPUBLICBLOB");
const BCRYPT_RSA_ALGORITHM_W = std.unicode.utf8ToUtf16LeStringLiteral("RSA");
const BCRYPT_PAD_OAEP: ULONG = 0x00000004;
const BCRYPT_PAD_PKCS1: ULONG = 0x00000002;
const BCRYPT_SHA256_W = std.unicode.utf8ToUtf16LeStringLiteral("SHA256");

const BCRYPT_OAEP_PADDING_INFO = extern struct {
    pszAlgId: [*:0]const u16,
    pbLabel: ?*anyopaque,
    cbLabel: ULONG,
};

const BCRYPT_RSAKEY_BLOB = extern struct {
    Magic: u32,
    BitLength: u32,
    cbPublicExp: u32,
    cbModulus: u32,
    cbPrime1: u32,
    cbPrime2: u32,
};

// ── RsaKeyPair: cross-platform RSA key management ──

pub const RsaKeyPair = struct {
    allocator: std.mem.Allocator,
    // Windows: BCrypt key handle
    key_handle: if (is_windows) ?BCRYPT_KEY_HANDLE else void,
    alg_handle: if (is_windows) ?BCRYPT_ALG_HANDLE else void,
    // Linux: PEM private key stored in memory
    private_key_pem: if (!is_windows) ?[]const u8 else void,

    pub fn generate(allocator: std.mem.Allocator) !RsaKeyPair {
        if (comptime is_windows) {
            return generateWindows(allocator);
        } else {
            return generateLinux(allocator);
        }
    }

    fn generateWindows(allocator: std.mem.Allocator) !RsaKeyPair {
        var alg: BCRYPT_ALG_HANDLE = undefined;
        var status = BCryptOpenAlgorithmProvider(&alg, BCRYPT_RSA_ALGORITHM_W, null, 0);
        if (status != 0) return error.CryptoError;

        var key: BCRYPT_KEY_HANDLE = undefined;
        status = BCryptGenerateKeyPair(alg, &key, 2048, 0);
        if (status != 0) {
            _ = BCryptCloseAlgorithmProvider(alg, 0);
            return error.CryptoError;
        }

        status = BCryptFinalizeKeyPair(key, 0);
        if (status != 0) {
            _ = BCryptDestroyKey(key);
            _ = BCryptCloseAlgorithmProvider(alg, 0);
            return error.CryptoError;
        }

        return .{
            .allocator = allocator,
            .key_handle = key,
            .alg_handle = alg,
            .private_key_pem = {},
        };
    }

    fn generateLinux(allocator: std.mem.Allocator) !RsaKeyPair {
        // Use openssl CLI to generate RSA keypair
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "openssl", "genrsa", "2048" },
            .max_output_bytes = 8192,
        }) catch return error.CryptoError;
        defer allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            allocator.free(result.stdout);
            return error.CryptoError;
        }

        return .{
            .allocator = allocator,
            .key_handle = {},
            .alg_handle = {},
            .private_key_pem = result.stdout,
        };
    }

    pub fn deinit(self: *RsaKeyPair) void {
        if (comptime is_windows) {
            if (self.key_handle) |k| _ = BCryptDestroyKey(k);
            if (self.alg_handle) |a| _ = BCryptCloseAlgorithmProvider(a, 0);
            self.key_handle = null;
            self.alg_handle = null;
        } else {
            if (self.private_key_pem) |pem| self.allocator.free(pem);
            self.private_key_pem = null;
        }
    }

    /// Export public key as PKCS#1 DER, base64url encoded (no padding)
    pub fn exportPublicKeyB64(self: *RsaKeyPair, allocator: std.mem.Allocator) ![]const u8 {
        if (comptime is_windows) {
            return self.exportPublicKeyB64Windows(allocator);
        } else {
            return self.exportPublicKeyB64Linux(allocator);
        }
    }

    fn exportPublicKeyB64Windows(self: *RsaKeyPair, allocator: std.mem.Allocator) ![]const u8 {
        const key = self.key_handle orelse return error.NoKey;

        // Get export size
        var blob_size: ULONG = 0;
        var status = BCryptExportKey(key, null, BCRYPT_RSAPUBLIC_BLOB_W, null, 0, &blob_size, 0);
        if (status != 0) return error.CryptoError;

        const blob = try allocator.alloc(u8, blob_size);
        defer allocator.free(blob);

        var actual_size: ULONG = 0;
        status = BCryptExportKey(key, null, BCRYPT_RSAPUBLIC_BLOB_W, blob.ptr, blob_size, &actual_size, 0);
        if (status != 0) return error.CryptoError;

        // Parse BCRYPT_RSAKEY_BLOB to get exponent and modulus
        const header: *const BCRYPT_RSAKEY_BLOB = @ptrCast(@alignCast(blob.ptr));
        const exp_offset: usize = @sizeOf(BCRYPT_RSAKEY_BLOB);
        const mod_offset = exp_offset + header.cbPublicExp;
        const exponent = blob[exp_offset .. exp_offset + header.cbPublicExp];
        const modulus = blob[mod_offset .. mod_offset + header.cbModulus];

        // Encode as PKCS#1 DER
        const der = try encodePkcs1Der(allocator, modulus, exponent);
        defer allocator.free(der);

        // base64url encode (no padding)
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const b64_len = encoder.calcSize(der.len);
        const b64 = try allocator.alloc(u8, b64_len);
        _ = encoder.encode(b64, der);
        return b64;
    }

    fn exportPublicKeyB64Linux(self: *RsaKeyPair, allocator: std.mem.Allocator) ![]const u8 {
        const pem = self.private_key_pem orelse return error.NoKey;

        // Write PEM to temp file, extract public key in DER format
        const tmp_priv = "zed2api_tmp_priv.pem";
        const tmp_pub = "zed2api_tmp_pub.der";
        defer std.fs.cwd().deleteFile(tmp_priv) catch {};
        defer std.fs.cwd().deleteFile(tmp_pub) catch {};

        {
            const f = std.fs.cwd().createFile(tmp_priv, .{}) catch return error.CryptoError;
            defer f.close();
            f.writeAll(pem) catch return error.CryptoError;
        }

        // Extract public key as PKCS#1 DER (RSAPublicKey format)
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "openssl", "rsa", "-in", tmp_priv, "-pubout", "-outform", "DER", "-RSAPublicKey_out", "-out", tmp_pub },
            .max_output_bytes = 4096,
        }) catch return error.CryptoError;
        allocator.free(result.stdout);
        allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) return error.CryptoError;

        // Read DER file
        const der_file = std.fs.cwd().openFile(tmp_pub, .{}) catch return error.CryptoError;
        defer der_file.close();
        const der = der_file.readToEndAlloc(allocator, 4096) catch return error.CryptoError;
        defer allocator.free(der);

        // base64url encode (no padding)
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const b64_len = encoder.calcSize(der.len);
        const b64 = try allocator.alloc(u8, b64_len);
        _ = encoder.encode(b64, der);
        return b64;
    }

    /// Decrypt ciphertext using RSA-OAEP SHA-256
    pub fn decrypt(self: *RsaKeyPair, allocator: std.mem.Allocator, ciphertext: []const u8) ![]const u8 {
        if (comptime is_windows) {
            return self.decryptWindows(allocator, ciphertext);
        } else {
            return self.decryptLinux(allocator, ciphertext);
        }
    }

    fn decryptWindows(self: *RsaKeyPair, allocator: std.mem.Allocator, ciphertext: []const u8) ![]const u8 {
        const key = self.key_handle orelse return error.NoKey;

        var padding_info = BCRYPT_OAEP_PADDING_INFO{
            .pszAlgId = BCRYPT_SHA256_W,
            .pbLabel = null,
            .cbLabel = 0,
        };

        // Get output size
        var out_size: ULONG = 0;
        var status = BCryptDecrypt(key, ciphertext.ptr, @intCast(ciphertext.len), @ptrCast(&padding_info), null, 0, null, 0, &out_size, BCRYPT_PAD_OAEP);
        if (status != 0) return error.DecryptFailed;

        const output = try allocator.alloc(u8, out_size);
        var actual: ULONG = 0;
        status = BCryptDecrypt(key, ciphertext.ptr, @intCast(ciphertext.len), @ptrCast(&padding_info), null, 0, output.ptr, out_size, &actual, BCRYPT_PAD_OAEP);
        if (status != 0) {
            allocator.free(output);
            return error.DecryptFailed;
        }

        if (actual < out_size) {
            const trimmed = allocator.realloc(output, actual) catch return output;
            return trimmed;
        }
        return output;
    }

    fn decryptLinux(self: *RsaKeyPair, allocator: std.mem.Allocator, ciphertext: []const u8) ![]const u8 {
        const pem = self.private_key_pem orelse return error.NoKey;

        const tmp_priv = "zed2api_tmp_dec_priv.pem";
        const tmp_enc = "zed2api_tmp_enc.bin";
        defer std.fs.cwd().deleteFile(tmp_priv) catch {};
        defer std.fs.cwd().deleteFile(tmp_enc) catch {};

        // Write private key
        {
            const f = std.fs.cwd().createFile(tmp_priv, .{}) catch return error.DecryptFailed;
            defer f.close();
            f.writeAll(pem) catch return error.DecryptFailed;
        }
        // Write ciphertext
        {
            const f = std.fs.cwd().createFile(tmp_enc, .{}) catch return error.DecryptFailed;
            defer f.close();
            f.writeAll(ciphertext) catch return error.DecryptFailed;
        }

        // Decrypt with OAEP SHA-256
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "openssl", "pkeyutl", "-decrypt", "-inkey", tmp_priv, "-in", tmp_enc, "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256" },
            .max_output_bytes = 8192,
        }) catch return error.DecryptFailed;
        defer allocator.free(result.stderr);

        if (result.term != .Exited or result.term.Exited != 0) {
            allocator.free(result.stdout);
            return error.DecryptFailed;
        }

        return result.stdout;
    }
};


// ── DER encoding helpers for PKCS#1 RSAPublicKey ──

fn encodePkcs1Der(allocator: std.mem.Allocator, modulus: []const u8, exponent: []const u8) ![]const u8 {
    // PKCS#1 RSAPublicKey ::= SEQUENCE { modulus INTEGER, publicExponent INTEGER }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    // Encode inner: modulus INTEGER + exponent INTEGER
    var inner: std.ArrayListUnmanaged(u8) = .empty;
    defer inner.deinit(allocator);
    const iw = inner.writer(allocator);
    try derWriteInteger(iw, modulus);
    try derWriteInteger(iw, exponent);

    // SEQUENCE tag + length + inner
    try w.writeByte(0x30);
    try derWriteLength(w, inner.items.len);
    try w.writeAll(inner.items);

    return try allocator.dupe(u8, buf.items);
}

fn derWriteInteger(w: anytype, data: []const u8) !void {
    // Skip leading zeros but keep at least one byte
    var start: usize = 0;
    while (start < data.len - 1 and data[start] == 0) start += 1;
    const trimmed = data[start..];

    // If high bit set, prepend 0x00
    const needs_pad = (trimmed[0] & 0x80) != 0;
    const total_len = trimmed.len + @as(usize, if (needs_pad) 1 else 0);

    try w.writeByte(0x02); // INTEGER tag
    try derWriteLength(w, total_len);
    if (needs_pad) try w.writeByte(0x00);
    try w.writeAll(trimmed);
}

fn derWriteLength(w: anytype, length: usize) !void {
    if (length < 128) {
        try w.writeByte(@intCast(length));
    } else if (length < 256) {
        try w.writeByte(0x81);
        try w.writeByte(@intCast(length));
    } else {
        try w.writeByte(0x82);
        try w.writeByte(@intCast(length >> 8));
        try w.writeByte(@intCast(length & 0xFF));
    }
}

// ── Browser launch ──

pub fn openBrowserPublic(url: []const u8) void {
    openBrowser(url);
}

fn openBrowser(url: []const u8) void {
    if (comptime is_windows) {
        openBrowserWindows(url);
    } else {
        openBrowserLinux(url);
    }
}

fn openBrowserWindows(url: []const u8) void {
    // Try Chrome incognito first
    _ = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "cmd", "/c", "start", "chrome", "--incognito", url },
        .max_output_bytes = 256,
    }) catch {
        // Try Edge inprivate
        _ = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "cmd", "/c", "start", "msedge", "--inprivate", url },
            .max_output_bytes = 256,
        }) catch {
            // Try Firefox private
            _ = std.process.Child.run(.{
                .allocator = std.heap.page_allocator,
                .argv = &.{ "cmd", "/c", "start", "firefox", "--private-window", url },
                .max_output_bytes = 256,
            }) catch {
                // Fallback: rundll32 (no private mode but at least opens)
                _ = std.process.Child.run(.{
                    .allocator = std.heap.page_allocator,
                    .argv = &.{ "rundll32", "url.dll,FileProtocolHandler", url },
                    .max_output_bytes = 256,
                }) catch {};
            };
        };
    };
}

fn openBrowserLinux(url: []const u8) void {
    // Try Chrome incognito first
    _ = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &.{ "google-chrome", "--incognito", url },
        .max_output_bytes = 256,
    }) catch {
        // Try Chromium incognito
        _ = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{ "chromium", "--incognito", url },
            .max_output_bytes = 256,
        }) catch {
            // Try Firefox private
            _ = std.process.Child.run(.{
                .allocator = std.heap.page_allocator,
                .argv = &.{ "firefox", "--private-window", url },
                .max_output_bytes = 256,
            }) catch {
                // Fallback: xdg-open
                _ = std.process.Child.run(.{
                    .allocator = std.heap.page_allocator,
                    .argv = &.{ "xdg-open", url },
                    .max_output_bytes = 256,
                }) catch {};
            };
        };
    };
}

// ── Platform-adapted socket I/O for auth callback server ──

fn authSocketRecv(stream: std.net.Stream, buf: []u8) !usize {
    if (comptime is_windows) {
        const ws2 = std.os.windows.ws2_32;
        const rc = ws2.recv(stream.handle, buf.ptr, @intCast(buf.len), 0);
        if (rc == ws2.SOCKET_ERROR) return error.RecvFailed;
        if (rc == 0) return 0;
        return @intCast(rc);
    } else {
        return stream.read(buf);
    }
}

fn authSocketSend(stream: std.net.Stream, data: []const u8) !void {
    if (comptime is_windows) {
        const ws2 = std.os.windows.ws2_32;
        var sent: usize = 0;
        while (sent < data.len) {
            const rc = ws2.send(stream.handle, data[sent..].ptr, @intCast(data.len - sent), 0);
            if (rc == ws2.SOCKET_ERROR) return error.SendFailed;
            sent += @intCast(rc);
        }
    } else {
        _ = try stream.write(data);
    }
}


// ── URL decoding ──

fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .empty;
    defer result.deinit(allocator);
    const w = result.writer(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexVal(input[i + 1]) orelse {
                try w.writeByte(input[i]);
                i += 1;
                continue;
            };
            const lo = hexVal(input[i + 2]) orelse {
                try w.writeByte(input[i]);
                i += 1;
                continue;
            };
            try w.writeByte((hi << 4) | lo);
            i += 3;
        } else if (input[i] == '+') {
            try w.writeByte(' ');
            i += 1;
        } else {
            try w.writeByte(input[i]);
            i += 1;
        }
    }
    return try allocator.dupe(u8, result.items);
}

fn hexVal(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// ── Login flow ──

/// CLI login: generate keypair, start local server, open browser, wait for callback
pub fn login(allocator: std.mem.Allocator) !Credentials {
    var keypair = try RsaKeyPair.generate(allocator);
    defer keypair.deinit();

    const pub_key = try keypair.exportPublicKeyB64(allocator);
    defer allocator.free(pub_key);

    const addr = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    var tcp = try addr.listen(.{});
    defer tcp.deinit();
    const port = tcp.listen_address.getPort();

    const url = try std.fmt.allocPrint(allocator, "https://zed.dev/native_app_signin?native_app_port={d}&native_app_public_key={s}", .{ port, pub_key });
    defer allocator.free(url);

    std.debug.print("[login] opening browser...\n  {s}\n", .{url});
    openBrowser(url);

    std.debug.print("[login] waiting for callback on port {d}...\n", .{port});
    return loginWithServer(allocator, &keypair, &tcp);
}

/// Wait for OAuth callback on an already-listening TCP server
pub fn loginWithServer(allocator: std.mem.Allocator, keypair: *RsaKeyPair, tcp: *std.net.Server) !Credentials {
    const conn = tcp.accept() catch return error.AcceptFailed;
    defer conn.stream.close();

    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = authSocketRecv(conn.stream, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
    }

    const data = buf[0..total];
    // Parse GET /?user_id=...&access_token=...
    const first_line_end = std.mem.indexOf(u8, data, "\r\n") orelse return error.BadCallback;
    const first_line = data[0..first_line_end];

    // Extract path from "GET /path HTTP/1.1"
    var parts = std.mem.splitScalar(u8, first_line, ' ');
    _ = parts.next(); // GET
    const full_path = parts.next() orelse return error.BadCallback;

    // Parse query string
    const query_start = std.mem.indexOf(u8, full_path, "?") orelse return error.BadCallback;
    const query = full_path[query_start + 1 ..];

    var user_id: ?[]const u8 = null;
    var encrypted_token: ?[]const u8 = null;
    defer if (user_id) |u| allocator.free(u);

    var query_parts = std.mem.splitScalar(u8, query, '&');
    while (query_parts.next()) |param| {
        const eq = std.mem.indexOf(u8, param, "=") orelse continue;
        const key = param[0..eq];
        const val = param[eq + 1 ..];
        if (std.mem.eql(u8, key, "user_id")) {
            user_id = try urlDecode(allocator, val);
        } else if (std.mem.eql(u8, key, "access_token")) {
            encrypted_token = try urlDecode(allocator, val);
        }
    }

    const uid = user_id orelse return error.NoUserId;
    const enc_tok = encrypted_token orelse return error.NoToken;

    // Decode base64url ciphertext
    // Add padding if needed
    var padded_buf: [4096]u8 = undefined;
    const pad_needed = (4 - (enc_tok.len % 4)) % 4;
    if (enc_tok.len + pad_needed > padded_buf.len) return error.TokenTooLong;
    @memcpy(padded_buf[0..enc_tok.len], enc_tok);
    for (0..pad_needed) |j| padded_buf[enc_tok.len + j] = '=';
    const padded = padded_buf[0 .. enc_tok.len + pad_needed];

    const decoder = std.base64.url_safe.Decoder;
    const decoded_len = decoder.calcSizeForSlice(padded) catch return error.BadBase64;
    const ciphertext = try allocator.alloc(u8, decoded_len);
    defer allocator.free(ciphertext);
    decoder.decode(ciphertext, padded) catch return error.BadBase64;

    // Decrypt
    const plaintext = try keypair.decrypt(allocator, ciphertext);
    defer allocator.free(plaintext);

    // Send redirect response
    const redirect = "HTTP/1.1 302 Found\r\nLocation: https://zed.dev/native_app_signin_succeeded\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    authSocketSend(conn.stream, redirect) catch {};

    // plaintext is the access_token JSON string
    const result_uid = try allocator.dupe(u8, uid);
    const result_token = try allocator.dupe(u8, plaintext);

    std.debug.print("[login] success! user_id: {s}\n", .{result_uid});

    return .{
        .user_id = result_uid,
        .access_token = result_token,
    };
}
