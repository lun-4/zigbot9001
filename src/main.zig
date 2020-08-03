const std = @import("std");
const hzzp = @import("hzzp");
const wz = @import("wz");
const ssl = @import("zig-bearssl");

const agent = "zigbot9001/0.0.1";

const SslTunnel = struct {
    allocator: *std.mem.Allocator,

    trust_anchor: ssl.TrustAnchorCollection,
    x509: ssl.x509.Minimal,
    client: ssl.Client,

    raw_conn: std.fs.File,
    // TODO: why do these need to be overaligned?
    raw_reader: std.fs.File.Reader align(8),
    raw_writer: std.fs.File.Writer align(8),

    conn: ssl.Stream(*std.fs.File.Reader, *std.fs.File.Writer),

    fn init(args: struct {
        allocator: *std.mem.Allocator,
        pem: []const u8,
        host: [:0]const u8,
        port: u16 = 443,
    }) !*SslTunnel {
        const result = try args.allocator.create(SslTunnel);
        errdefer args.allocator.destroy(result);

        result.allocator = args.allocator;

        result.trust_anchor = ssl.TrustAnchorCollection.init(args.allocator);
        errdefer result.trust_anchor.deinit();
        try result.trust_anchor.appendFromPEM(args.pem);

        result.x509 = ssl.x509.Minimal.init(result.trust_anchor);
        result.client = ssl.Client.init(result.x509.getEngine());
        result.client.relocate();
        try result.client.reset(args.host, false);

        result.raw_conn = try std.net.tcpConnectToHost(args.allocator, args.host, args.port);
        errdefer result.raw_conn.close();

        result.raw_reader = result.raw_conn.reader();
        result.raw_writer = result.raw_conn.writer();

        result.conn = ssl.initStream(result.client.getEngine(), &result.raw_reader, &result.raw_writer);

        return result;
    }

    fn deinit(self: *SslTunnel) void {
        self.conn.close() catch {};
        self.raw_conn.close();
        self.trust_anchor.deinit();

        self.* = undefined;
        errdefer self.allocator.destroy(self);
    }
};

pub fn requestGithubIssue(issue: u32) !void {
    var ssl_tunnel = try SslTunnel.init(.{
        .allocator = std.heap.c_allocator,
        .pem = @embedFile("../github-com-chain.pem"),
        .host = "api.github.com",
    });
    errdefer ssl_tunnel.deinit();

    var buf: [0x1000]u8 = undefined;
    var client = hzzp.BaseClient.create(&buf, ssl_tunnel.conn.inStream(), ssl_tunnel.conn.outStream());

    var path: [0x100]u8 = undefined;
    try client.writeHead("GET", try std.fmt.bufPrint(&path, "/repos/ziglang/zig/issues/{}", .{issue}));

    try client.writeHeader("Host", "api.github.com");
    try client.writeHeader("User-Agent", agent);
    try client.writeHeader("Accept", "application/json");
    try client.writeHeadComplete();
    try ssl_tunnel.conn.flush();

    if (try client.readEvent()) |event| {
        if (event != .status) {
            return error.MissingStatus;
        }
        switch (event.status.code) {
            200 => {}, // success!
            404 => return error.NotFound,
            else => @panic("Response not expected"),
        }
    } else {
        return error.NoResponse;
    }

    // Skip headers
    while (try client.readEvent()) |event| {
        if (event == .head_complete) {
            break;
        }
    }

    var reader = hzzpChunkReader(client);
    var tmp: [0x1000]u8 = undefined;
    while (try reader.reader().readUntilDelimiterOrEof(&tmp, ',')) |line| {
        std.debug.print("{}\n", .{line});
    }
}

fn hzzpChunkReader(client: anytype) HzzpChunkReader(@TypeOf(client)) {
    return .{ .client = client };
}

fn HzzpChunkReader(comptime Client: type) type {
    return struct {
        const Self = @This();
        const Reader = std.io.Reader(*Self, Client.ReadError, readFn);

        client: Client,
        complete: bool = false,
        chunk: ?hzzp.BaseClient.Chunk = null,
        loc: usize = undefined,

        fn readFn(self: *Self, buffer: []u8) Client.ReadError!usize {
            if (self.complete) return 0;

            if (self.chunk) |chunk| {
                const remaining = chunk.data[self.loc..];
                if (buffer.len < remaining.len) {
                    std.mem.copy(u8, buffer, remaining[0..buffer.len]);
                    self.loc += buffer.len;
                    return buffer.len;
                } else {
                    std.mem.copy(u8, buffer, remaining);
                    if (chunk.final) {
                        self.complete = true;
                    }
                    self.chunk = null;
                    return remaining.len;
                }
            } else {
                const event = (try self.client.readEvent()) orelse {
                    self.complete = true;
                    return 0;
                };

                if (event != .chunk) {
                    self.complete = true;
                    return 0;
                }

                if (buffer.len < event.chunk.data.len) {
                    std.mem.copy(u8, buffer, event.chunk.data[0..buffer.len]);
                    self.chunk = event.chunk;
                    self.loc = buffer.len;
                    return buffer.len;
                } else {
                    std.mem.copy(u8, buffer, event.chunk.data);
                    if (event.chunk.final) {
                        self.complete = true;
                    }
                    return event.chunk.data.len;
                }
            }
        }

        pub fn reader(self: *Self) Reader {
            return .{ .context = self };
        }
    };
}

pub fn main() !void {
    // try requestGithubIssue(5076);
    try discord();
}

pub fn discord() !void {
    var ssl_tunnel = try SslTunnel.init(.{
        .allocator = std.heap.c_allocator,
        .pem = @embedFile("../discord-gg-chain.pem"),
        .host = "gateway.discord.gg",
    });
    errdefer ssl_tunnel.deinit();

    var buf: [0x1000]u8 = undefined;
    var client = wz.BaseClient.create(&buf, ssl_tunnel.conn.inStream(), ssl_tunnel.conn.outStream());

    // Handshake
    var handshake_headers = std.http.Headers.init(std.heap.c_allocator);
    defer handshake_headers.deinit();
    try handshake_headers.append("Host", "gateway.discord.gg", null);
    try client.sendHandshake(&handshake_headers, "/?v=6&encoding=json");
    try ssl_tunnel.conn.flush();
    try client.waitForHandshake();

    // Identify
    try client.writer.print(
        \\ {{
        \\   "op": 2,
        \\   "d": {{
        \\     "token": "{0}",
        \\     "properties": {{
        \\       "$os": "{1}",
        \\       "$browser": "{2}",
        \\       "$device": "{2}"
        \\     }}
        \\   }}
        \\ }}
    ,
        .{
            "Bot 12345",
            "linux",
            "zigbot9001/0.0.1",
        },
    );
    try ssl_tunnel.conn.flush();

    while (try client.readEvent()) |event| {
        std.debug.print("{}\n\n", .{event});
    }
    std.debug.print("Terminus\n\n", .{});
}
