const std = @import("std");
const ThreadPool = @import("threadPool.zig");

pub fn serveStatic(ctx: ThreadPool.RequestContext) !void {
    const allocator = ctx.allocator;
    const route = ctx.route;

    const cwd = std.fs.cwd();

    const file = try cwd.openFile(try std.fmt.allocPrint(allocator, "static/{s}", .{route}), .{ .mode = .read_only });
    defer file.close();

    const file_contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(file_contents);

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
