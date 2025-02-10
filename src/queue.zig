// implemented request queue to avoid overwhelming the server
const std = @import("std");
const net = std.net;

pub const QueueError = error{
    QueueFull,
    QueueEmpty,
    QueueClosed,
};

pub const RequestQueue = struct {
    const Self = @This();

    queue: std.ArrayList(net.Server.Connection),
    mutex: std.Thread.Mutex,
    empty_cond: std.Thread.Condition,
    full_cond: std.Thread.Condition,
    max_size: usize,
    closed: bool,

    stats: Stats,

    pub const Stats = struct {
        total_enqueued: usize = 0,
        total_dequeued: usize = 0,
        rejected_count: usize = 0,
        high_water_mark: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator, max_size: usize) Self {
        return .{
            .queue = std.ArrayList(net.Server.Connection).init(allocator),
            .mutex = std.Thread.Mutex{},
            .empty_cond = std.Thread.Condition{},
            .full_cond = std.Thread.Condition{},
            .max_size = max_size,
            .closed = false,
            .stats = Stats{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.closed = true;
        self.empty_cond.broadcast();
        self.full_cond.broadcast();
        self.queue.deinit();
    }

    pub fn enqueue(self: *Self, client: net.Server.Connection) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.closed) return QueueError.QueueClosed;

        while (self.queue.items.len >= self.max_size) {
            if (self.closed) return QueueError.QueueClosed;
            self.stats.rejected_count += 1;
            self.full_cond.wait(&self.mutex);
        }

        try self.queue.append(client);
        self.stats.total_enqueued += 1;

        if (self.queue.items.len > self.stats.high_water_mark) {
            self.stats.high_water_mark = self.queue.items.len;
        }

        self.empty_cond.signal();
    }

    pub fn dequeue(self: *Self) !net.Server.Connection {
        self.mutex.lock();
        defer self.mutex.unlock();

        // wait if queue is empty
        while (self.queue.items.len == 0) {
            if (self.closed) return QueueError.QueueClosed;
            self.empty_cond.wait(&self.mutex);
        }

        const client = self.queue.orderedRemove(0);
        self.stats.total_dequeued += 1;
        self.full_cond.signal();

        return client;
    }

    pub fn getStats(self: *Self) Stats {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stats;
    }

    pub fn getCurrentSize(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.items.len;
    }
};
