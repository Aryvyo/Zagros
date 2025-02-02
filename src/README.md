

#Example of how to serve a page
```
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

throw this in main.zig, or anywhere else i guess, or you can just embedFile and load it and send that
or do it dynamically
up to you man

then to serve it

`try pool.addRoute("", handleIndex);`

same procedure for serving a stylesheet etc, just ensure the routes match up, in the above example you'd have

`try pool.addRoute("styles.css", serveCss);` etc

rough implementation for now thinking of how to make this more intuitive 
