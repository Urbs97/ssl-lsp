const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");
const types = @import("../types.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, id: ?std.json.Value, params: std.json.Value) anyerror!void {
    const req_id = id orelse return;

    const td = helpers.getObject(params, "textDocument") orelse {
        log.err("definition: missing 'textDocument'", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };
    const uri = helpers.getString(td, "uri") orelse {
        log.err("definition: missing 'uri'", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };
    const position = helpers.getObject(params, "position") orelse {
        log.err("definition: missing 'position'", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };
    const line = helpers.getInteger(position, "line") orelse {
        log.err("definition: missing 'position.line'", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };
    const character = helpers.getInteger(position, "character") orelse {
        log.err("definition: missing 'position.character'", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    const doc = ctx.documents.getPtr(uri) orelse {
        log.debug("definition: unknown document {s}", .{uri});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    var pr = doc.parse_result orelse {
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    const word = helpers.getWordAtPosition(doc.text, @intCast(line), @intCast(character)) orelse {
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    // Search procedures
    for (0..pr.num_procs) |i| {
        const proc = pr.getProc(i);
        if (std.mem.eql(u8, proc.name, word)) {
            const decl_line: u32 = if (proc.declared_line > 0) proc.declared_line - 1 else 0;
            const name_len: u32 = @intCast(proc.name.len);
            const loc = types.Location{
                .uri = uri,
                .range = .{
                    .start = .{ .line = decl_line, .character = 0 },
                    .end = .{ .line = decl_line, .character = name_len },
                },
            };
            try ctx.sendResponse(allocator, req_id, try loc.toJson(allocator));
            return;
        }
    }

    // Search global variables
    for (0..pr.num_vars) |i| {
        const v = pr.getVar(i);
        if (std.mem.eql(u8, v.name, word)) {
            const var_line: u32 = if (v.declared_line > 0) v.declared_line - 1 else 0;
            const name_len: u32 = @intCast(v.name.len);
            const loc = types.Location{
                .uri = uri,
                .range = .{
                    .start = .{ .line = var_line, .character = 0 },
                    .end = .{ .line = var_line, .character = name_len },
                },
            };
            try ctx.sendResponse(allocator, req_id, try loc.toJson(allocator));
            return;
        }
    }

    // Search local variables in each procedure
    for (0..pr.num_procs) |pi| {
        const proc = pr.getProc(pi);
        for (0..proc.num_local_vars) |vi| {
            const local_var = pr.getProcVar(pi, vi);
            if (std.mem.eql(u8, local_var.name, word)) {
                const var_line: u32 = if (local_var.declared_line > 0) local_var.declared_line - 1 else 0;
                const name_len: u32 = @intCast(local_var.name.len);
                const loc = types.Location{
                    .uri = uri,
                    .range = .{
                        .start = .{ .line = var_line, .character = 0 },
                        .end = .{ .line = var_line, .character = name_len },
                    },
                };
                try ctx.sendResponse(allocator, req_id, try loc.toJson(allocator));
                return;
            }
        }
    }

    // No match found
    try ctx.sendResponse(allocator, req_id, .null);
}
