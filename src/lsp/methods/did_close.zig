const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, _: ?std.json.Value, params: std.json.Value) anyerror!void {
    const uri = helpers.getTextDocumentUri(params) orelse {
        log.err("didClose: missing textDocument.uri", .{});
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
