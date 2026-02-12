const std = @import("std");
const Context = @import("../context.zig").Context;

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, id: ?std.json.Value, _: std.json.Value) anyerror!void {
    ctx.shutdown_requested = true;
    try ctx.sendResponse(allocator, id orelse .null, .null);
    log.info("shutdown requested", .{});
}
