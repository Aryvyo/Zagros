const std = @import("std");
const ThreadPool = @import("threadPool.zig");

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
    content: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, route: []const u8, content: []const u8, modified: i128) !*StaticFile {
        const self = try allocator.create(StaticFile);
        self.* = .{
            .modified = modified,
            .route = try allocator.dupe(u8, route),
            .content = try allocator.dupe(u8, content),
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *StaticFile) void {
        self.allocator.free(self.route);
        self.allocator.free(self.content);
        self.allocator.destroy(self);
    }
};

pub const StaticFileServer = struct {
    files: std.StringHashMap(*StaticFile),
    allocator: std.mem.Allocator,
    onChange: *const fn (FileEvent, *ThreadPool.ThreadPool) anyerror!void,
    pool: *ThreadPool.ThreadPool,

    pub fn init(allocator: std.mem.Allocator, onChange: *const fn (FileEvent, *ThreadPool.ThreadPool) anyerror!void, pool: *ThreadPool.ThreadPool) StaticFileServer {
        return .{
            .files = std.StringHashMap(*StaticFile).init(allocator),
            .allocator = allocator,
            .onChange = onChange,
            .pool = pool,
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

pub fn serveStatic(ctx: ThreadPool.RequestContext) !void {
    const allocator = ctx.allocator;
    const route = ctx.route;

    const cwd = std.fs.cwd();

    const file = try cwd.openFile(try std.fmt.allocPrint(allocator, "static/{s}", .{route}), .{ .mode = .read_only });
    defer file.close();

    const file_contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    var content_type: []const u8 = "";
    if (std.mem.endsWith(u8, route, ".html")) {
        content_type = "text/html";
    } else if (std.mem.endsWith(u8, route, ".css")) {
        content_type = "text/css";
    } else if (std.mem.endsWith(u8, route, ".js")) {
        content_type = "application/javascript";
    }

    const response = try std.fmt.allocPrint(allocator, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ content_type, file_contents.len, file_contents });
    defer allocator.free(response);
    try ctx.client_writer.writeAll(response);
}
