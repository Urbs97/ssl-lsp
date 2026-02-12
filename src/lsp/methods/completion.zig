const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");
const types = @import("../types.zig");
const builtins = @import("../builtins.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, id: ?std.json.Value, params: std.json.Value) anyerror!void {
    const req_id = id orelse return;

    const uri = helpers.getTextDocumentUri(params) orelse {
        log.err("completion: missing textDocument.uri", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };
    const pos = helpers.getPosition(params) orelse {
        log.err("completion: missing position params", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    const doc = ctx.documents.getPtr(uri) orelse {
        log.debug("completion: unknown document {s}", .{uri});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    const prefix = helpers.getWordPrefixAtPosition(doc.text, @intCast(pos.line), @intCast(pos.character)) orelse {
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    var items = std.json.Array.init(allocator);

    // Built-in opcodes
    for (builtins.opcodes()) |op| {
        if (std.ascii.startsWithIgnoreCase(op.name, prefix)) {
            const item = types.CompletionItem{
                .label = op.name,
                .kind = .Function,
                .detail = op.signature,
                .documentation = if (op.description.len > 0) op.description else null,
            };
            try items.append(try item.toJson(allocator));
        }
    }

    // User-defined procedures and variables from parse result
    if (doc.parse_result) |*pr| {
        for (0..pr.num_procs) |i| {
            const proc = pr.getProc(i);
            if (std.ascii.startsWithIgnoreCase(proc.name, prefix)) {
                const item = types.CompletionItem{
                    .label = proc.name,
                    .kind = .Function,
                };
                try items.append(try item.toJson(allocator));
            }
        }

        for (0..pr.num_vars) |i| {
            const v = pr.getVar(i);
            if (std.ascii.startsWithIgnoreCase(v.name, prefix)) {
                const item = types.CompletionItem{
                    .label = v.name,
                    .kind = .Variable,
                };
                try items.append(try item.toJson(allocator));
            }
        }

        // Local variables from each procedure
        for (0..pr.num_procs) |pi| {
            const proc = pr.getProc(pi);
            for (0..proc.num_local_vars) |vi| {
                const local_var = pr.getProcVar(pi, vi);
                if (std.ascii.startsWithIgnoreCase(local_var.name, prefix)) {
                    const item = types.CompletionItem{
                        .label = local_var.name,
                        .kind = .Variable,
                    };
                    try items.append(try item.toJson(allocator));
                }
            }
        }
    }

    try ctx.sendResponse(allocator, req_id, .{ .array = items });
}
