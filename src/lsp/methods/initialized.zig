const std = @import("std");
const Context = @import("../context.zig").Context;

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, _: std.mem.Allocator, _: ?std.json.Value, _: std.json.Value) anyerror!void {
    ctx.initialized = true;
    log.info("client initialized", .{});
}
