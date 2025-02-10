const std = @import("std");
const net = std.net;
const f = @import("file.zig");
const threadPool = @import("threadPool.zig");
const utils = @import("utils.zig");
const static = @import("static.zig");
const cache = @import("cache.zig");
const config = @import("config.zig");
const RequestQueue = @import("queue.zig").RequestQueue;

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

fn processRequests(pool: *threadPool.ThreadPool, queue: *RequestQueue) !void {
    while (true) {
        const client = queue.dequeue() catch |err| {
            if (err == error.QueueClosed) break;
            std.debug.print("Error dequeuing request: {any}\n", .{err});
            continue;
        };
        try pool.submit(client);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var serverConfig = try config.ServerConfig.loadFromFile(allocator, "server.cfg");
    defer serverConfig.deinit();

    var fileCache = cache.Cache.init(allocator);
    defer fileCache.deinit();

    var pool = try threadPool.ThreadPool.init(allocator, serverConfig.thread_count, &fileCache);
    defer pool.deinit();
    try pool.start();

    // initialize request queue, make it configurable
    const MAX_QUEUE_SIZE = 1000;
    var request_queue = RequestQueue.init(allocator, MAX_QUEUE_SIZE);
    defer request_queue.deinit();

    // start worker threads for processing requests, make it configurable
    const WORKER_COUNT = 4;
    var workers: [WORKER_COUNT]std.Thread = undefined;
    for (&workers) |*worker| {
        worker.* = try std.Thread.spawn(.{}, processRequests, .{ &pool, &request_queue });
    }
    defer for (workers) |worker| worker.join();

    const addr = try net.Address.resolveIp(serverConfig.address, serverConfig.port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    // now you can click when starting
    std.debug.print("Server listening on \x1B]8;;http://{s}:{d}\x07http://{s}:{d}\x1B]8;;\x07\n", .{ serverConfig.address, serverConfig.port, serverConfig.address, serverConfig.port });

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

    // main server loop with request queue and monitoring
    while (true) {
        const client = server.accept() catch |err| {
            std.debug.print("Error accepting connection: {any}\n", .{err});
            continue;
        };

        request_queue.enqueue(client) catch |err| {
            std.debug.print("Failed to enqueue request: {any}\n", .{err});
            client.stream.close();
            continue;
        };

        // print stats every 100 requests, make config to disable it
        if (request_queue.getCurrentSize() % 100 == 0) {
            const stats = request_queue.getStats();
            std.debug.print(
                \\queue stats:
                \\  Current size: {d}
                \\  Total enqueued: {d}
                \\  Total dequeued: {d}
                \\  Rejected: {d}
                \\  High Water Mark: {d}
                \\
            , .{
                request_queue.getCurrentSize(),
                stats.total_enqueued,
                stats.total_dequeued,
                stats.rejected_count,
                stats.high_water_mark,
            });
        }
    }
}
