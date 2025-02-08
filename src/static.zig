const std = @import("std");
const ThreadPool = @import("threadPool.zig");
const cache = @import("cache.zig");

pub const FileChange = enum {
    added,
    modified,
    deleted,
};

pub const FileEvent = struct {
    path: []const u8,
    change: FileChange,
};

pub const StaticFile = struct {
    modified: i128,
    route: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, route: []const u8, modified: i128) !*StaticFile {
        const self = try allocator.create(StaticFile);
        self.* = .{
            .modified = modified,
            .route = try allocator.dupe(u8, route),
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *StaticFile) void {
        self.allocator.free(self.route);
        self.allocator.destroy(self);
    }
};

pub const StaticFileServer = struct {
    files: std.StringHashMap(*StaticFile),
    allocator: std.mem.Allocator,
    onChange: *const fn (FileEvent, *ThreadPool.ThreadPool) anyerror!void,
    pool: *ThreadPool.ThreadPool,
    fileCache: *cache.Cache,

    pub fn init(
        allocator: std.mem.Allocator,
        onChange: *const fn (FileEvent, *ThreadPool.ThreadPool) anyerror!void,
        pool: *ThreadPool.ThreadPool,
        fileCache: *cache.Cache,
    ) StaticFileServer {
        return .{
            .files = std.StringHashMap(*StaticFile).init(allocator),
            .allocator = allocator,
            .onChange = onChange,
            .pool = pool,
            .fileCache = fileCache,
        };
    }

    pub fn deinit(self: *StaticFileServer) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.files.deinit();
    }

    pub fn checkForChanges(self: *StaticFileServer) !void {
        const cwd = std.fs.cwd();
        var static_dir = try cwd.openDir("static", .{ .iterate = true });
        defer static_dir.close();

        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        var dir_iterator = static_dir.iterate();
        while (try dir_iterator.next()) |entry| {
            if (entry.kind == .file) {
                try seen.put(entry.name, {});

                const file = try static_dir.openFile(entry.name, .{});
                defer file.close();
                const stat = try file.stat();
                const contents = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
                defer self.allocator.free(contents);

                try self.fileCache.put(entry.name, contents, stat.mtime);

                //i think this is kind of dumb and janky and stupid but i honestly cannot be bothered to write something nicer looking than this, thousand apologies
                if (std.mem.eql(u8, entry.name, "index.html")) {
                    try self.onChange(.{
                        .path = "",
                        .change = if (self.files.contains(entry.name)) .modified else .added,
                    }, self.pool);
                }

                if (self.files.get(entry.name)) |known_file| {
                    if (known_file.modified != stat.mtime) {
                        std.debug.print("File changed detected: {s}\n", .{entry.name});
                        known_file.modified = stat.mtime;
                        try self.onChange(.{
                            .path = entry.name,
                            .change = .modified,
                        }, self.pool);
                    }
                } else {
                    std.debug.print("New file found: {s}\n", .{entry.name});
                    const new_file = try StaticFile.init(self.allocator, entry.name, stat.mtime);
                    try self.files.put(entry.name, new_file);
                    try self.onChange(.{
                        .path = entry.name,
                        .change = .added,
                    }, self.pool);
                }
            }
        }
    }
};

// TODO: investigate why its ever so slightly slower since implementing etags (.3ms -> 2ms)?
pub fn serveStatic(ctx: ThreadPool.RequestContext) !void {
    const allocator = ctx.allocator;
    const route = ctx.route;

    if (ctx.fileCache.get(route)) |entry| {
        if (ctx.headers.get("If-None-Match")) |client_etag| {
            if (std.mem.eql(u8, client_etag, entry.etag)) {
                const not_modified = try std.fmt.allocPrint(allocator,
                    \\HTTP/1.1 304 Not Modified
                    \\ETag: {s}
                    \\Cache-Control: public, max-age=3600
                    \\
                    \\
                , .{entry.etag});
                try ctx.client_writer.writeAll(not_modified);
                return;
            }
        }

        const response = try std.fmt.allocPrint(allocator,
            \\HTTP/1.1 200 OK
            \\Content-Type: {s}
            \\Content-Length: {d}
            \\ETag: {s}
            \\Cache-Control: public, max-age=3600
            \\
            \\{s}
        , .{
            getContentType(route),
            entry.contents.len,
            entry.etag,
            entry.contents,
        });
        defer allocator.free(response);
        try ctx.client_writer.writeAll(response);
        return;
    }

    const cwd = std.fs.cwd();
    const file = try cwd.openFile(try std.fmt.allocPrint(allocator, "static/{s}", .{route}), .{ .mode = .read_only });
    defer file.close();
    const file_contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_contents);

    var hasher = std.hash.Wyhash.init(0);
    hasher.update(file_contents);
    const hash = hasher.final();
    const etag = try std.fmt.allocPrint(allocator, "\"{x}\"", .{hash});
    defer allocator.free(etag);

    const response = try std.fmt.allocPrint(allocator,
        \\HTTP/1.1 200 OK
        \\Content-Type: {s}
        \\Content-Length: {d}
        \\ETag: {s}
        \\Cache-Control: public, max-age=3600
        \\
        \\{s}
    , .{
        getContentType(route),
        file_contents.len,
        etag,
        file_contents,
    });
    defer allocator.free(response);
    try ctx.client_writer.writeAll(response);
}

fn getContentType(route: []const u8) []const u8 {
    if (std.mem.endsWith(u8, route, ".html")) {
        return "text/html";
    } else if (std.mem.endsWith(u8, route, ".css")) {
        return "text/css";
    } else if (std.mem.endsWith(u8, route, ".js")) {
        return "application/javascript";
    }
    return "application/octet-stream";
}
