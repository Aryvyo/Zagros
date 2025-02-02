const std = @import("std");

pub fn parseCookies(allocator: std.mem.Allocator, cookie_header: []const u8) std.StringHashMap([]const u8) {
    var cookies = std.StringHashMap([]const u8).init(allocator);
    var iter = std.mem.split(u8, cookie_header, ";");

    while (iter.next()) |cookie| {
        var cookie_trimmed = std.mem.trim(u8, cookie, " ");

        if (std.mem.indexOf(u8, cookie_trimmed, "=")) |separator| {
            const key = cookie_trimmed[0..separator];
            const value = cookie_trimmed[separator + 1 ..];
            cookies.put(key, value) catch continue;
        }
    }

    return cookies;
}

pub fn getPath(first_line: []const u8, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    // Split "GET /path HTTP/1.1" into parts
    var iter = std.mem.splitAny(u8, first_line, " ");
    _ = iter.next() orelse return error.InvalidRequest; // Skip HTTP method
    const path = iter.next() orelse return error.InvalidRequest;
    var pathIter = std.mem.splitAny(u8, path, "/");
    _ = pathIter.next();
    var paths = std.ArrayList([]const u8).init(allocator);
    while (pathIter.next()) |split| {
        try paths.append(split);
    }
    return paths;
}

pub fn generatePostDivs(allocator: std.mem.Allocator, posts: []const []const u8) ![]u8 {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    for (posts) |post| {
        const safe_post = try escapeHtml(allocator, post);
        defer allocator.free(safe_post);

        try buffer.appendSlice("<div class='post'>");
        try buffer.appendSlice(safe_post);
        try buffer.appendSlice("</div>");
    }

    return try buffer.toOwnedSlice();
}

pub fn urlDecode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hex = input[i + 1 .. i + 3];
            const value = try std.fmt.parseInt(u8, hex, 16);
            try result.append(value);
            i += 3;
        } else if (input[i] == '+') {
            try result.append(' ');
            i += 1;
        } else {
            try result.append(input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

pub fn parseFormData(allocator: std.mem.Allocator, body: []const u8) !std.StringHashMap([]const u8) {
    var form_data = std.StringHashMap([]const u8).init(allocator);
    var pairs = std.mem.split(u8, body, "&");

    while (pairs.next()) |pair| {
        var kv = std.mem.split(u8, pair, "=");
        if (kv.next()) |key| {
            if (kv.next()) |value| {
                // URL decode the key and value
                const decoded_key = try urlDecode(allocator, key);
                const decoded_value = try urlDecode(allocator, value);
                try form_data.put(decoded_key, decoded_value);
            }
        }
    }
    return form_data;
}

pub fn escapeHtml(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var output = std.ArrayList(u8).init(allocator);
    for (input) |char| {
        switch (char) {
            '<' => try output.appendSlice(" "),
            '>' => try output.appendSlice(" "),
            '&' => try output.appendSlice("&amp;"),
            '"' => try output.appendSlice(" "),
            '\'' => try output.appendSlice(" "),
            else => try output.append(char),
        }
    }
    return output.toOwnedSlice();
}
