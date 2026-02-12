const std = @import("std");
const Context = @import("../context.zig").Context;

pub fn handle(ctx: *Context, _: std.mem.Allocator, _: ?std.json.Value, _: std.json.Value) anyerror!void {
    const exit_code: u8 = if (ctx.shutdown_requested) 0 else 1;
    std.process.exit(exit_code);
}
