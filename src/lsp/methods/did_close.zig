const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, _: ?std.json.Value, params: std.json.Value) anyerror!void {
    const td = helpers.getObject(params, "textDocument") orelse {
        log.err("didClose: missing 'textDocument'", .{});
        return;
    };
    const uri = helpers.getString(td, "uri") orelse {
        log.err("didClose: missing 'uri'", .{});
        return;
    };

    if (ctx.documents.fetchRemove(uri)) |entry| {
        ctx.allocator.free(entry.key);
        var doc = entry.value;
        doc.deinit();
    }

    // Clear diagnostics for closed file
    try ctx.publishDiagnostics(allocator, uri, "");
    log.info("closed: {s}", .{uri});
}
