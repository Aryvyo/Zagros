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
