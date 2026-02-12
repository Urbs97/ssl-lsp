const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, _: ?std.json.Value, params: std.json.Value) anyerror!void {
    const uri = helpers.getTextDocumentUri(params) orelse {
        log.err("didChange: missing textDocument.uri", .{});
        return;
    };

    // Full sync mode: contentChanges[0].text has the full content
    const changes = helpers.getArray(params, "contentChanges") orelse {
        log.err("didChange: missing 'contentChanges'", .{});
        return;
    };
    if (changes.len == 0) return;
    const text = helpers.getString(changes[0], "text") orelse return;

    if (ctx.documents.getPtr(uri)) |doc| {
        doc.allocator.free(doc.text);
        doc.text = try doc.allocator.dupe(u8, text);
    }

    try ctx.publishDiagnostics(allocator, uri, text);
}
