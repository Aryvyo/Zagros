const std = @import("std");

pub fn loadStaticHtml(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

pub fn loadTemplateHtml(allocator: std.mem.Allocator, path: []const u8, args: []const []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

    const response = try std.fmt.allocPrint(allocator, content, args);

    return response;
}

pub fn gzipCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var compressed = std.ArrayList(u8).init(allocator);
    errdefer compressed.deinit();

    var compressor = try std.compress.gzip.compressor(compressed.writer(), .{});
    //we should deinit the compressor right? but it has no deinit function? peculiar

    _ = try compressor.write(data);
    try compressor.finish();

    std.debug.print("{s}", .{try compressed.toOwnedSlice()});
    return compressed.toOwnedSlice();
}

pub fn shouldCompress(content_type: []const u8, content_length: usize) bool {
    if (content_length < 1024) return false;

    // Common compressible types
    const compressible = [_][]const u8{
        "text/",
        "application/javascript",
        "application/json",
        "application/xml",
        "application/x-yaml",
        "application/ld+json",
    };

    for (compressible) |typ| {
        if (std.mem.startsWith(u8, content_type, typ)) return true;
    }

    return false;
}
