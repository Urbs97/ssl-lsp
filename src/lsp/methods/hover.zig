const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");
const types = @import("../types.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, id: ?std.json.Value, params: std.json.Value) anyerror!void {
    const req_id = id orelse return;

    const uri = helpers.getTextDocumentUri(params) orelse {
        log.err("hover: missing textDocument.uri", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };
    const pos = helpers.getPosition(params) orelse {
        log.err("hover: missing position params", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    const doc = ctx.documents.getPtr(uri) orelse {
        log.debug("hover: unknown document {s}", .{uri});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    var pr = doc.parse_result orelse {
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    const word = helpers.getWordAtPosition(doc.text, @intCast(pos.line), @intCast(pos.character)) orelse {
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    // Search procedures
    for (0..pr.num_procs) |i| {
        const proc = pr.getProc(i);
        if (std.mem.eql(u8, proc.name, word)) {
            const md = try helpers.formatProcHover(allocator, proc, i, &pr, doc.text);
            const hover_result = types.Hover{ .contents = .{ .value = md } };
            try ctx.sendResponse(allocator, req_id, try hover_result.toJson(allocator));
            return;
        }
    }

    // Search global variables
    for (0..pr.num_vars) |i| {
        const v = pr.getVar(i);
        if (std.mem.eql(u8, v.name, word)) {
            const md = try helpers.formatVarHover(allocator, v, null, &pr, doc.text);
            const hover_result = types.Hover{ .contents = .{ .value = md } };
            try ctx.sendResponse(allocator, req_id, try hover_result.toJson(allocator));
            return;
        }
    }

    // Search local variables in each procedure
    for (0..pr.num_procs) |pi| {
        const proc = pr.getProc(pi);
        for (0..proc.num_local_vars) |vi| {
            const local_var = pr.getProcVar(pi, vi);
            if (std.mem.eql(u8, local_var.name, word)) {
                const md = try helpers.formatVarHover(allocator, local_var, proc.name, &pr, doc.text);
                const hover_result = types.Hover{ .contents = .{ .value = md } };
                try ctx.sendResponse(allocator, req_id, try hover_result.toJson(allocator));
                return;
            }
        }
    }

    // No match found
    try ctx.sendResponse(allocator, req_id, .null);
}
