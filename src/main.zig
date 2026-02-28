const std = @import("std");
const coro = @import("coroutine");

pub fn main() !void {
    var co: coro.Coroutine(coro.ReturnType(myCoroutine)) = undefined;
    defer co.deinit();

    try co.init(.{}, myCoroutine, .{});

    var delta: i96 = 0;
    // getting time doesn't use the coroutine. So this is
    // safe.
    const start = std.Io.Timestamp.now(co.any.io(), .boot);
    var lt = start;
    while (!(try co.@"resume"())) {
        const now = std.Io.Timestamp.now(co.any.io(), .boot);
        const dt = lt.durationTo(now);
        lt = now;
        delta += dt.nanoseconds;
        if (delta >= std.time.ns_per_s) {
            delta = 0;
            std.log.info("Still waiting on connection... ({D} elapsed)", .{
                @as(i64, @intCast(start.durationTo(now).nanoseconds)),
            });
        }
    }
}

fn myCoroutine(co: *coro.AnyCoroutine) !void {
    const coio = co.io();

    const addr = std.Io.net.IpAddress{ .ip4 = .loopback(25565) };
    var server = try addr.listen(coio, .{ .reuse_address = true });
    defer server.deinit(coio);

    const conn = try server.accept(coio);
    defer conn.close(coio);

    var rbuf: [64]u8 = undefined;
    var wbuf: [64]u8 = undefined;
    var sr = conn.reader(coio, &rbuf);
    var sw = conn.writer(coio, &wbuf);
    const reader = &sr.interface;
    const writer = &sw.interface;

    while (true) {
        const s = reader.peekGreedy(1) catch |err| return switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => sr.err.?,
        };

        writer.writeAll(s) catch unreachable;
        try writer.flush();
        reader.toss(s.len);
    }
}
