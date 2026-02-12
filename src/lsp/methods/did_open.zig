const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, _: ?std.json.Value, params: std.json.Value) anyerror!void {
    const td = helpers.getObject(params, "textDocument") orelse {
        log.err("didOpen: missing 'textDocument'", .{});
        return;
    };
    const uri = helpers.getString(td, "uri") orelse {
        log.err("didOpen: missing 'uri'", .{});
        return;
    };
    const text = helpers.getString(td, "text") orelse {
        log.err("didOpen: missing 'text'", .{});
        return;
    };

    const uri_dupe = try ctx.allocator.dupe(u8, uri);
    const text_dupe = try ctx.allocator.dupe(u8, text);

    const result = try ctx.documents.getOrPut(ctx.allocator, uri_dupe);
    if (result.found_existing) {
        ctx.allocator.free(result.key_ptr.*);
        result.value_ptr.deinit();
        result.key_ptr.* = uri_dupe;
    }
    result.value_ptr.* = .{ .allocator = ctx.allocator, .text = text_dupe };

    log.info("opened: {s}", .{uri});
    try ctx.publishDiagnostics(allocator, uri, text);
}
