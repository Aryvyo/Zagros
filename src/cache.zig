const std = @import("std");

pub const CacheEntry = struct {
    contents: []const u8,
    modified: i128,
    etag: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, contents: []const u8, modified: i128) !*CacheEntry {
        const self = try allocator.create(CacheEntry);

        var hasher = std.hash.Wyhash.init(0);
        hasher.update(contents);
        const hash = std.hash.Wyhash.hash(0, contents);
        std.debug.print("{any}", .{hash});
        const etag = try std.fmt.allocPrint(allocator, "\"{any}\"", .{hash});
        self.* = .{
            .contents = try allocator.dupe(u8, contents),
            .modified = modified,
            .allocator = allocator,
            .etag = etag,
        };
        return self;
    }

    pub fn deinit(self: *CacheEntry) void {
        self.allocator.free(self.contents);
        self.allocator.free(self.etag);
        self.allocator.destroy(self);
    }

    pub fn update(self: *CacheEntry, newContents: []const u8, newModified: i128) anyerror!void {
        const dupedContents = try self.allocator.dupe(u8, newContents);

        const hash = std.hash.Wyhash.hash(0, dupedContents);
        const newEtag = try std.fmt.allocPrint(self.allocator, "\"{any}\"", .{hash});

        self.allocator.free(self.contents);
        self.allocator.free(self.etag);

        self.contents = dupedContents;
        self.etag = newEtag;
        self.modified = newModified;
    }
};

pub const Cache = struct {
    entries: std.StringHashMap(*CacheEntry),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .entries = std.StringHashMap(*CacheEntry).init(allocator),
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.entries.deinit();
    }

    pub fn get(self: *Cache, key: []const u8) ?*CacheEntry {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.get(key);
    }

    pub fn put(self: *Cache, key: []const u8, contents: []const u8, modified: i128) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.get(key)) |entry| {
            try entry.update(contents, modified);
        } else {
            const entry = try CacheEntry.init(self.allocator, contents, modified);
            try self.entries.put(key, entry);
        }
    }

    pub fn remove(self: *Cache, key: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.fetchRemove(key)) |entry| {
            entry.value.deinit();
        }
    }
};
