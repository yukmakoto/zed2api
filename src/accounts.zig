const std = @import("std");

pub const Account = struct {
    name: []const u8,
    user_id: []const u8,
    credential_json: []const u8,
    jwt_token: ?[]const u8 = null,
    jwt_exp: i64 = 0,
};

pub const AccountManager = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(Account) = .empty,
    current: usize = 0,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) AccountManager {
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *AccountManager) void {
        self.list.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn getCurrent(self: *AccountManager) ?*Account {
        if (self.list.items.len == 0) return null;
        return &self.list.items[self.current];
    }

    pub fn switchTo(self: *AccountManager, name: []const u8) bool {
        for (self.list.items, 0..) |acc, i| {
            if (std.mem.eql(u8, acc.name, name)) {
                self.current = i;
                return true;
            }
        }
        return false;
    }

    pub fn loadFromFile(self: *AccountManager) !void {
        const alloc = self.arena.allocator();
        const file = std.fs.cwd().openFile("accounts.json", .{}) catch return;
        defer file.close();

        const content = try file.readToEndAlloc(alloc, 4 * 1024 * 1024);
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, content, .{});
        const root = parsed.value;

        const accs_val = root.object.get("accounts") orelse return;
        var it = accs_val.object.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const val = entry.value_ptr.*;
            if (val != .object) continue;

            const obj = val.object;
            const uid = blk: {
                const v = obj.get("user_id") orelse continue;
                break :blk switch (v) {
                    .string => |s| s,
                    .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
                    else => continue,
                };
            };

            const cred_val = obj.get("credential") orelse continue;
            const cred_json = std.json.Stringify.valueAlloc(alloc, cred_val, .{}) catch continue;

            self.list.append(self.allocator, .{
                .name = name,
                .user_id = uid,
                .credential_json = cred_json,
            }) catch continue;
        }
    }
};

pub fn addAccount(allocator: std.mem.Allocator, name: []const u8, user_id: []const u8, access_token_json: []const u8) !void {
    // Read existing
    var buf: [4 * 1024 * 1024]u8 = undefined;
    var existing_content: ?[]const u8 = null;

    if (std.fs.cwd().openFile("accounts.json", .{})) |file| {
        defer file.close();
        const n = try file.readAll(&buf);
        existing_content = buf[0..n];
    } else |_| {}

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(allocator);
    const w = output.writer(allocator);

    var has_existing = false;
    if (existing_content) |content| {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value.object.get("accounts")) |accs| {
                try w.writeAll("{\n  \"accounts\": {\n");
                var it = accs.object.iterator();
                var first = true;
                while (it.next()) |entry| {
                    if (!first) try w.writeAll(",\n");
                    first = false;
                    try w.print("    \"{s}\": ", .{entry.key_ptr.*});
                    const val_str = try std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{});
                    defer allocator.free(val_str);
                    try w.writeAll(val_str);
                    has_existing = true;
                }
                if (has_existing) try w.writeAll(",\n");
                try w.print("    \"{s}\": {{\"user_id\":\"{s}\",\"credential\":{s}}}", .{ name, user_id, access_token_json });
                try w.writeAll("\n  }\n}");
            }
        }
    }

    if (!has_existing and existing_content == null) {
        try w.print("{{\n  \"accounts\": {{\n    \"{s}\": {{\"user_id\":\"{s}\",\"credential\":{s}}}\n  }}\n}}", .{ name, user_id, access_token_json });
    }

    const file = try std.fs.cwd().createFile("accounts.json", .{});
    defer file.close();
    try file.writeAll(output.items);
}
