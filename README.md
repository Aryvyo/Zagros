

# Zagros

A simple, fast server built in Zig!

I started this project for fun, and have been working on it for the same reason since. If there are parts that just aren't good code, or you disagree with, feel free to let me know in an issue or contribute to fix it! I'm here to learn before everything else and I understand I'll make mistakes or do stuff the 'wrong' way :)

## PATCH NOTES 0.2
- Fixed queue overlapping removal bug
- Added option to display time taken to fulfill request in config (`display_time`)
- Added cli option to regenerate (This will overwrite the old one) default config (`./Zagros -c` or `./Zagros --config`)
- Improved error handling in worker function (should cover most cases, open issue if the server still implodes after an error)
- Temporarily removed the static file watcher server
- Removed herobrine


## Installation

Requirements:

- Zig 0.13

The server is very DIY, if you wish to run it:

```bash
  git clone https://github.com/Aryvyo/Zagros.git
  cd Zagros
  zig build run
```

This barebones compile will read from (and create) a `static/` directory, any files in this directory will be served as is under a route with their file name.

    
## Configuration

Upon first startup, the program will generate a `server.cfg` file

This will contain the following:

```
# Server Configuration
# Default configuration file created automatically

# Network settings
address = 127.0.0.1
port = 8080

# Performance settings
thread_count = 4

#Print time taken per request
display_time = false 
```

## Reference

The main functions you'll care about are:

#### Add a route 

`
  ThreadPool.addRoute(path: []const u8, method:HttpMethod, handler: RouterFn);
`

#### Parse form data

`
  utils.parseFormData(allocator:std.mem.Allocator,body:[]const u8);
` 

which returns a `StringHasmap([]const u8)`



## Example
```zig
fn handleIndex(ctx: ThreadPool.RequestContext) !void {
    const html =
        \\<html lang="en">
        \\<head>
        \\ <meta charset="UTF-8">
        \\ <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\<link rel="stylesheet" href="styles.css">
        \\<title>Example</title>
        \\<link rel="icon" href="data:,">
        \\</head>
        \\<body>
        \\</body>
        \\</html>
        \\
    ;

    const filledhtml = try std.fmt.allocPrint(ctx.allocator, html);
    const response = try std.fmt.allocPrint(ctx.allocator,
        \\HTTP/1.1 200 OK
        \\Content-Type: text/html
        \\Content-Length: {d}
        \\Connection: close
        \\
        \\{s}
    , .{ filledhtml.len, filledhtml });
    defer ctx.allocator.free(response);

    try ctx.client_writer.writeAll(response);
}
```

throw this in `main.zig`, or anywhere else i guess, or you can just embedFile and load it and send that

or do it dynamically

up to you man

then to serve it

`try pool.addRoute("", .GET, handleIndex);`

same procedure for serving a stylesheet etc, just ensure the routes match up, in the above example you'd have

`try pool.addRoute("styles.css", .GET, serveCss);` etc

(rough implementation for now thinking of how to make this more intuitive)


## Contributing

Contributions are always welcome!

Just open a PR and I'll read over it!



