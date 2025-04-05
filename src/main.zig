const std = @import("std");
const net = std.net;
const f = @import("file.zig");
const threadPool = @import("threadPool.zig");
const utils = @import("utils.zig");
const static = @import("static.zig");
const cache = @import("cache.zig");
const config = @import("config.zig");

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
            try pool.addRoute(event.path, .GET, static.serveStatic);
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

fn writeConfigAndQuit() !void {
    _ = try config.ServerConfig.createDefaultConfig("server.cfg");

    std.process.exit(1);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            _ = try writeConfigAndQuit();
        }
    }
    var serverConfig = try config.ServerConfig.loadFromFile(allocator, "server.cfg");
    defer serverConfig.deinit();

    var fileCache = cache.Cache.init(allocator);
    defer fileCache.deinit();

    var pool = try threadPool.ThreadPool.init(allocator, serverConfig.thread_count, &fileCache, serverConfig);
    defer pool.deinit();
    try pool.start();

    const addr = try net.Address.resolveIp(serverConfig.address, serverConfig.port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    std.debug.print("Server listening on {s}:{d}\n", .{ serverConfig.address, serverConfig.port });

    var staticServer = static.StaticFileServer.init(
        allocator,
        handleFileChange,
        &pool,
        &fileCache,
    );
    defer staticServer.deinit();

    try staticServer.checkForChanges();

    //const WatcherContext = struct {
    //    fn watch(sServer: *static.StaticFileServer) !void {
    //        while (true) {
    //            sServer.checkForChanges() catch |err| {
    //                std.debug.print("Error occurred watching for changes: {any}\n", .{err});
    //            };
    //            std.time.sleep(1 * std.time.ns_per_s);
    //        }
    //    }
    //};

    //const watcher = try std.Thread.spawn(.{}, WatcherContext.watch, .{&staticServer});
    //defer watcher.join();

    while (true) {
        const client = try server.accept();
        try pool.submit(client);
    }
}
