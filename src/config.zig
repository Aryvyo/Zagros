//last file i promise
const std = @import("std");

pub const ServerConfig = struct {
    address: []const u8,
    port: u16,
    thread_count: u8,
    display_time: bool,
    allocator: std.mem.Allocator,

    const default_config =
        \\# Server Configuration
        \\# Default configuration file created automatically
        \\
        \\# Network settings
        \\address = 127.0.0.1
        \\port = 8080
        \\
        \\# Performance settings
        \\thread_count = 4
        \\
        \\#Print time taken per request
        \\display_time = false 
    ;

    pub fn init(allocator: std.mem.Allocator) !ServerConfig {
        return .{
            .address = try allocator.dupe(u8, "127.0.0.1"),
            .port = 8080,
            .thread_count = 4,
            .display_time = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ServerConfig) void {
        self.allocator.free(self.address);
    }

    fn createDefaultConfig(path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{
            .read = true,
            .truncate = true,
        });
        defer file.close();

        try file.writeAll(default_config);
        std.debug.print("Created default configuration file at {s}\n", .{path});
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !ServerConfig {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                try createDefaultConfig(path);
                return ServerConfig.init(allocator);
            }
            return err;
        };
        defer file.close();

        var config = try ServerConfig.init(allocator);
        errdefer config.deinit();

        const reader = file.reader();
        var buf: [1024]u8 = undefined;

        while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r\n");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (std.mem.indexOf(u8, trimmed, "=")) |sep_index| {
                const key = std.mem.trim(u8, trimmed[0..sep_index], " \t");
                const value = std.mem.trim(u8, trimmed[sep_index + 1 ..], " \t");

                if (std.mem.eql(u8, key, "address")) {
                    allocator.free(config.address);
                    config.address = try allocator.dupe(u8, value);
                } else if (std.mem.eql(u8, key, "port")) {
                    config.port = try std.fmt.parseInt(u16, value, 10);
                } else if (std.mem.eql(u8, key, "thread_count")) {
                    config.thread_count = try std.fmt.parseInt(u8, value, 10);
                } else if (std.mem.eql(u8, key, "display_time")) {
                    config.display_time = std.mem.eql(u8, value, "true");
                }
            }
        }

        return config;
    }

    pub fn print(self: *const ServerConfig) void {
        std.debug.print(
            \\Server Configuration:
            \\  Address: {s}
            \\  Port: {d}
            \\  Thread Count: {d}
            \\  Display Time: {}
            \\
        , .{
            self.address,
            self.port,
            self.thread_count,
            self.display_time,
        });
    }
};
