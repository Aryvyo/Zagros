const std = @import("std");
const net = std.net;
const utils = @import("utils.zig");

pub const RequestContext = struct {
    allocator: std.mem.Allocator,
    client_writer: std.net.Stream.Writer,
    client_reader: std.net.Stream.Reader,
    headers: std.StringHashMap([]const u8),
    route: []const u8,
};

pub const RouterFn = *const fn (RequestContext) anyerror!void;

pub const Router = struct {
    routes: std.StringHashMap(RouterFn),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .routes = std.StringHashMap(RouterFn).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit();
    }

    pub fn addRoute(self: *Router, path: []const u8, handler: RouterFn) !void {
        try self.routes.put(path, handler);
    }
};

pub const Job = struct {
    client: net.Server.Connection,
    arena: std.heap.ArenaAllocator,

    pub fn init(client: net.Server.Connection, allocator: std.mem.Allocator) Job {
        return .{ .client = client, .arena = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Job) void {
        _ = self.arena.reset(.free_all);
        self.arena.deinit();
        self.client.stream.close();
    }
};

pub const JobQueue = struct {
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    jobs: std.ArrayList(Job),

    pub fn init(allocator: std.mem.Allocator) JobQueue {
        return .{
            .mutex = .{},
            .condition = .{},
            .jobs = std.ArrayList(Job).init(allocator),
        };
    }

    pub fn deinit(self: *JobQueue) void {
        self.jobs.deinit();
    }

    pub fn push(self: *JobQueue, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.jobs.append(job);
        self.condition.signal();
    }

    pub fn waitAndPop(self: *JobQueue) *Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.jobs.items.len == 0) {
            self.condition.wait(&self.mutex);
        }
        return &self.jobs.items[0];
    }

    pub fn removeFront(self: *JobQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        _ = self.jobs.orderedRemove(0);
    }
};

pub const ThreadPool = struct {
    threads: []std.Thread,
    job_queue: JobQueue,
    allocator: std.mem.Allocator,
    shutdown: std.atomic.Value(bool),
    router: Router,

    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !ThreadPool {
        const threads = try allocator.alloc(std.Thread, thread_count);

        const pool = ThreadPool{
            .threads = threads,
            .job_queue = JobQueue.init(allocator),
            .allocator = allocator,
            .shutdown = std.atomic.Value(bool).init(false),
            .router = Router.init(allocator),
        };

        return pool;
    }

    pub fn deinit(self: *ThreadPool) void {
        self.shutdown.store(true, .release);
        self.job_queue.condition.broadcast();

        for (self.threads) |thread| {
            thread.join();
        }

        self.allocator.free(self.threads);
        self.job_queue.deinit();
        self.router.deinit();
    }

    fn workerFn(self: *ThreadPool) !void {
        while (!self.shutdown.load(.acquire)) {
            var timer = try std.time.Timer.start();

            const strt = timer.lap();

            const job_ptr = self.job_queue.waitAndPop();

            const jobAllocator = job_ptr.arena.allocator();
            var headers = std.StringHashMap([]const u8).init(jobAllocator);

            const client_reader = job_ptr.client.stream.reader();
            const client_writer = job_ptr.client.stream.writer();

            const path = if (try client_reader.readUntilDelimiterOrEofAlloc(jobAllocator, '\n', 65536)) |first_line|
                try utils.getPath(first_line, jobAllocator)
            else {
                return error.InvalidRequest;
            };

            std.debug.print("Requested path: /{s}, extras: {any}\n", .{ path.items[0], path.items[1..] });

            while (true) {
                const line = try client_reader.readUntilDelimiterOrEofAlloc(jobAllocator, '\n', 65536) orelse break;

                if (line.len <= 2) break;

                if (std.mem.indexOf(u8, line, ":")) |colon_index| {
                    const key = std.mem.trim(u8, line[0..colon_index], " \r");
                    const value = std.mem.trim(u8, line[colon_index + 1 ..], " \r");

                    const key_owned = try jobAllocator.dupe(u8, key);
                    const value_owned = try jobAllocator.dupe(u8, value);
                    try headers.put(key_owned, value_owned);
                }
            }

            const ctx = RequestContext{
                .allocator = jobAllocator,
                .client_writer = client_writer,
                .client_reader = client_reader,
                .headers = headers,
                .route = path.items[0],
            };

            if (self.router.routes.get(ctx.route)) |handler| {
                handler(ctx) catch |err| {
                    const error_response = switch (err) {
                        //add whatever errors you need here ig
                        else =>
                        \\HTTP/1.1 500 Internal Server Error
                        \\Content-Type: text/html
                        \\Content-Length: 37
                        \\
                        \\<h1>500 Internal Server Error</h1>
                        \\
                    };
                    client_writer.writeAll(error_response) catch {};
                    std.debug.print("Error in worker: {}\n", .{err});
                    job_ptr.deinit();
                    self.job_queue.removeFront();
                    return;
                };
            } else {
                const not_found_response =
                    \\HTTP/1.1 404 Not Found
                    \\Content-Type: text/html
                    \\
                    \\<h1>404 Not Found</h1>
                    \\
                ;
                try client_writer.writeAll(not_found_response);
            }

            client_writer.context.close();

            self.job_queue.removeFront();

            const end = timer.read();
            const elapsedtime = @as(f64, @floatFromInt(end - strt)) / 1_000_000_000.0;

            std.debug.print("Request took {d:.2}ms\n", .{elapsedtime});
        }
    }

    pub fn addRoute(self: *ThreadPool, path: []const u8, handler: RouterFn) !void {
        try self.router.addRoute(path, handler);
    }

    pub fn start(self: *ThreadPool) !void {
        for (self.threads) |*thread| {
            thread.* = try std.Thread.spawn(.{}, workerFn, .{self});
        }
    }

    pub fn submit(self: *ThreadPool, client: net.Server.Connection) !void {
        const job = Job.init(client, self.allocator);
        try self.job_queue.push(job);
    }
};
