const std = @import("std");
const net = std.net;
const utils = @import("utils.zig");
const cache = @import("cache.zig");

pub const HttpMethod = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS,
    HEAD,

    pub fn fromString(method: []const u8) ?HttpMethod {
        if (std.mem.eql(u8, method, "GET")) return .GET;
        if (std.mem.eql(u8, method, "POST")) return .POST;
        if (std.mem.eql(u8, method, "PUT")) return .PUT;
        if (std.mem.eql(u8, method, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, method, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, method, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, method, "HEAD")) return .HEAD;
        return null;
    }
};

pub const RequestContext = struct {
    allocator: std.mem.Allocator,
    client_writer: std.net.Stream.Writer,
    client_reader: std.net.Stream.Reader,
    headers: std.StringHashMap([]const u8),
    route: []const u8,
    method: HttpMethod,
    fileCache: *cache.Cache,
    body: ?[]const u8 = null,
};

pub const RouterFn = *const fn (RequestContext) anyerror!void;

pub const RouteHandler = struct {
    path: []const u8,
    method: HttpMethod,
    handler: RouterFn,
};

pub const Router = struct {
    routes: std.ArrayList(RouteHandler),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .routes = std.ArrayList(RouteHandler).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.path);
        }
        self.routes.deinit();
    }

    pub fn addRoute(self: *Router, path: []const u8, method: HttpMethod, handler: RouterFn) !void {
        try self.routes.append(.{ .path = try self.allocator.dupe(u8, path), .method = method, .handler = handler });
    }

    pub fn findHandler(self: *Router, path: []const u8, method: HttpMethod) ?RouterFn {
        for (self.routes.items) |route| {
            if (std.mem.eql(u8, route.path, path) and route.method == method) {
                return route.handler;
            }
        }
        return null;
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
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) JobQueue {
        return .{
            .mutex = .{},
            .condition = .{},
            .jobs = std.ArrayList(Job).init(allocator),
            .allocator = allocator,
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

    // return a copy instead of a pointer
    pub fn waitAndPop(self: *JobQueue) !Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.jobs.items.len == 0) {
            self.condition.wait(&self.mutex);
        }

        // make a copy of the job before removing it
        const job = self.jobs.items[0];
        _ = self.jobs.orderedRemove(0);

        return job;
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
    fileCache: *cache.Cache,

    pub fn init(allocator: std.mem.Allocator, thread_count: usize, fileCache: *cache.Cache) !ThreadPool {
        const threads = try allocator.alloc(std.Thread, thread_count);

        const pool = ThreadPool{
            .threads = threads,
            .job_queue = JobQueue.init(allocator),
            .allocator = allocator,
            .shutdown = std.atomic.Value(bool).init(false),
            .router = Router.init(allocator),
            .fileCache = fileCache,
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

            // get a copy of the job instead of a pointer
            const job = self.job_queue.waitAndPop() catch |err| {
                std.debug.print("Error getting job: {}\n", .{err});
                continue;
            };

            // use defer to ensure cleanup
            defer job.deinit();

            const jobAllocator = job.arena.allocator();
            var headers = std.StringHashMap([]const u8).init(jobAllocator);

            const client_reader = job.client.stream.reader();
            const client_writer = job.client.stream.writer();

            const first_line = (try client_reader.readUntilDelimiterOrEofAlloc(jobAllocator, '\n', 65536)) orelse return error.InvalidRequest;
            var firstLineIter = std.mem.split(u8, first_line, " ");
            const methodStr = firstLineIter.next() orelse return error.InvalidRequest;
            const pathRaw = firstLineIter.next() orelse return error.InvalidRequest;

            const method = HttpMethod.fromString(methodStr) orelse return error.UnsupportedMethod;
            const path = try utils.getPath(pathRaw, jobAllocator);

            std.debug.print("Requested path: /{s}, extras: {any}\n", .{ path.items[0], path.items[1..] });

            var contentLength: usize = 0;
            while (true) {
                const line = try client_reader.readUntilDelimiterOrEofAlloc(jobAllocator, '\n', 65536) orelse break;
                if (line.len <= 2) break;
                if (std.mem.indexOf(u8, line, ":")) |colonIndex| {
                    const key = std.mem.trim(u8, line[0..colonIndex], " \r");
                    const value = std.mem.trim(u8, line[colonIndex + 1 ..], " \r");

                    if (std.mem.eql(u8, key, "Content-Length")) {
                        contentLength = try std.fmt.parseInt(usize, value, 10);
                    }

                    try headers.put(try jobAllocator.dupe(u8, key), try jobAllocator.dupe(u8, value));
                }
            }

            var body: ?[]const u8 = null;
            if (contentLength > 0) {
                const bodyBuffer = try jobAllocator.alloc(u8, contentLength);
                _ = try client_reader.readAll(bodyBuffer);
                body = bodyBuffer;
            }

            const ctx = RequestContext{
                .allocator = jobAllocator,
                .client_writer = client_writer,
                .client_reader = client_reader,
                .headers = headers,
                .route = path.items[0],
                .method = method,
                .body = body,
                .fileCache = self.fileCache,
            };

            if (self.router.findHandler(ctx.route, ctx.method)) |handler| {
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
                    job.deinit();
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

    pub fn addRoute(self: *ThreadPool, path: []const u8, method: HttpMethod, handler: RouterFn) !void {
        try self.router.addRoute(path, method, handler);
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
