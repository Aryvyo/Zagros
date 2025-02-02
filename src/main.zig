const std = @import("std");
const net = std.net;
const f = @import("file.zig");
const ThreadPool = @import("threadPool.zig");
const utils = @import("utils.zig");

pub const RequestContext = struct {
    allocator: std.mem.Allocator,
    client_writer: std.io.Writer,
    client_reader: std.io.Reader,
    headers: std.StringHashMap([]const u8),
};

const http_response =
    \\HTTP/1.1 200 OK
    \\Content-Type: text/html
    \\Content-Length: {d}
    \\
    \\{s}
    \\
;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var pool = try ThreadPool.ThreadPool.init(allocator, 4);
    defer pool.deinit();
    try pool.start();

    const addr = try net.Address.resolveIp("127.0.0.1", 8080);
    var server = try addr.listen(.{});
    defer server.deinit();

    std.debug.print("Server listening on 127.0.0.1:8080\n", .{});

    while (true) {
        const client = try server.accept();
        try pool.submit(client);
    }
}
