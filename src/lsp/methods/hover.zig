const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");
const types = @import("../types.zig");
const defines_mod = @import("../defines.zig");
const builtins = @import("../builtins.zig");

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

    const word = helpers.getWordAtPosition(doc.text, @intCast(pos.line), @intCast(pos.character)) orelse {
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    // Search procedures and variables from parse result
    if (doc.parse_result) |*pr| {
        for (0..pr.num_procs) |i| {
            const proc = pr.getProc(i);
            if (std.ascii.eqlIgnoreCase(proc.name, word)) {
                const md = try helpers.formatProcHover(allocator, proc, i, pr, doc.text);
                const hover_result = types.Hover{ .contents = .{ .value = md } };
                try ctx.sendResponse(allocator, req_id, try hover_result.toJson(allocator));
                return;
            }
        }

        // Search global variables
        for (0..pr.num_vars) |i| {
            const v = pr.getVar(i);
            if (std.ascii.eqlIgnoreCase(v.name, word)) {
                const md = try helpers.formatVarHover(allocator, v, null, pr, doc.text);
                const hover_result = types.Hover{ .contents = .{ .value = md } };
                try ctx.sendResponse(allocator, req_id, try hover_result.toJson(allocator));
                return;
            }
        }

        // Search local variables in the enclosing procedure only
        const cursor_line: u32 = @intCast(pos.line + 1); // parser lines are 1-indexed
        for (0..pr.num_procs) |pi| {
            const proc = pr.getProc(pi);
            const start = proc.start_line orelse continue;
            const end = proc.end_line orelse continue;
            if (cursor_line >= start and cursor_line <= end) {
                for (0..proc.num_local_vars) |vi| {
                    const local_var = pr.getProcVar(pi, vi);
                    if (std.ascii.eqlIgnoreCase(local_var.name, word)) {
                        const md = try helpers.formatVarHover(allocator, local_var, proc.name, pr, doc.text);
                        const hover_result = types.Hover{ .contents = .{ .value = md } };
                        try ctx.sendResponse(allocator, req_id, try hover_result.toJson(allocator));
                        return;
                    }
                }
                break;
            }
        }
    }

    // Search #define macros
    if (doc.defines) |*defs| {
        if (defs.lookupCaseInsensitive(word)) |def| {
            const md = try defines_mod.formatHover(allocator, def);
            const hover_result = types.Hover{ .contents = .{ .value = md } };
            try ctx.sendResponse(allocator, req_id, try hover_result.toJson(allocator));
            return;
        }
    }

    // Search built-in opcodes
    for (builtins.opcodes()) |op| {
        if (std.ascii.eqlIgnoreCase(op.name, word)) {
            var out: std.Io.Writer.Allocating = .init(allocator);
            const w = &out.writer;
            try w.writeAll("```ssl\n");
            try w.writeAll(op.signature);
            try w.writeAll("\n```\n");
            if (op.description.len > 0) {
                try w.writeByte('\n');
                try w.writeAll(op.description);
                try w.writeByte('\n');
            }
            const hover_result = types.Hover{ .contents = .{ .value = out.written() } };
            try ctx.sendResponse(allocator, req_id, try hover_result.toJson(allocator));
            return;
        }
    }

    // No match found
    try ctx.sendResponse(allocator, req_id, .null);
}
