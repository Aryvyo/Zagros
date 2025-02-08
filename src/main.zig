const std = @import("std");
const net = std.net;
const f = @import("file.zig");
const threadPool = @import("threadPool.zig");
const utils = @import("utils.zig");
const static = @import("static.zig");
const cache = @import("cache.zig");

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

fn handleFileChange(event: static.FileEvent, pool: *threadPool.ThreadPool) !void {
    switch (event.change) {
        .added => {
            std.debug.print("Adding route for new file: {s}\n", .{event.path});
            try pool.addRoute(event.path, static.serveStatic);
        },
        .modified => {
            std.debug.print("File modified: {s}\n", .{event.path});
        },
        .deleted => {
            std.debug.print("File deleted: {s}\n", .{event.path});
            // TODO: try pool.removeRoute(event.path);
        },
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var fileCache = cache.Cache.init(allocator);
    defer fileCache.deinit();

    var pool = try threadPool.ThreadPool.init(allocator, 4, &fileCache);
    defer pool.deinit();
    try pool.start();

    const addr = try net.Address.resolveIp("127.0.0.1", 8080);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Server listening on 127.0.0.1:8080\n", .{});

    var staticServer = static.StaticFileServer.init(
        allocator,
        handleFileChange,
        &pool,
        &fileCache,
    );
    defer staticServer.deinit();

    try staticServer.checkForChanges();

    const WatcherContext = struct {
        fn watch(sServer: *static.StaticFileServer) !void {
            while (true) {
                sServer.checkForChanges() catch |err| {
                    std.debug.print("Error occurred watching for changes: {any}\n", .{err});
                };
                std.time.sleep(1 * std.time.ns_per_s);
            }
        }
    };

    const watcher = try std.Thread.spawn(.{}, WatcherContext.watch, .{&staticServer});
    defer watcher.join();

    while (true) {
        const client = try server.accept();
        try pool.submit(client);
    }
}
