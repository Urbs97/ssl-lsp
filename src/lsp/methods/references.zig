const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");
const types = @import("../types.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, id: ?std.json.Value, params: std.json.Value) anyerror!void {
    const req_id = id orelse return;

    const uri = helpers.getTextDocumentUri(params) orelse {
        log.err("references: missing textDocument.uri", .{});
        try ctx.sendResponse(allocator, req_id, .{ .array = std.json.Array.init(allocator) });
        return;
    };
    const pos = helpers.getPosition(params) orelse {
        log.err("references: missing position params", .{});
        try ctx.sendResponse(allocator, req_id, .{ .array = std.json.Array.init(allocator) });
        return;
    };

    const context = helpers.getObject(params, "context");
    const include_declaration = if (context) |ctx_obj| helpers.getBool(ctx_obj, "includeDeclaration") orelse false else false;

    const doc = ctx.documents.getPtr(uri) orelse {
        log.debug("references: unknown document {s}", .{uri});
        try ctx.sendResponse(allocator, req_id, .{ .array = std.json.Array.init(allocator) });
        return;
    };

    if (doc.parse_result == null) {
        try ctx.sendResponse(allocator, req_id, .{ .array = std.json.Array.init(allocator) });
        return;
    }
    const pr = &doc.parse_result.?;

    const word = helpers.getWordAtPosition(doc.text, @intCast(pos.line), @intCast(pos.character)) orelse {
        try ctx.sendResponse(allocator, req_id, .{ .array = std.json.Array.init(allocator) });
        return;
    };

    var locations = std.json.Array.init(allocator);

    // Search procedures
    for (0..pr.num_procs) |i| {
        const proc = pr.getProc(i);
        if (std.mem.eql(u8, proc.name, word)) {
            if (include_declaration) {
                const decl_line: u32 = if (proc.declared_line > 0) proc.declared_line - 1 else 0;
                const loc = types.Location{
                    .uri = uri,
                    .range = .{
                        .start = .{ .line = decl_line, .character = 0 },
                        .end = .{ .line = decl_line, .character = 0 },
                    },
                };
                try locations.append(try loc.toJson(allocator));
            }

            const refs = try pr.getProcRefs(i, allocator);
            for (refs) |ref| {
                const ref_line: u32 = if (ref.line > 0) ref.line - 1 else 0;
                const loc = types.Location{
                    .uri = uri,
                    .range = .{
                        .start = .{ .line = ref_line, .character = 0 },
                        .end = .{ .line = ref_line, .character = 0 },
                    },
                };
                try locations.append(try loc.toJson(allocator));
            }

            try ctx.sendResponse(allocator, req_id, .{ .array = locations });
            return;
        }
    }

    // Search global variables
    for (0..pr.num_vars) |i| {
        const v = pr.getVar(i);
        if (std.mem.eql(u8, v.name, word)) {
            if (include_declaration) {
                const var_line: u32 = if (v.declared_line > 0) v.declared_line - 1 else 0;
                const loc = types.Location{
                    .uri = uri,
                    .range = .{
                        .start = .{ .line = var_line, .character = 0 },
                        .end = .{ .line = var_line, .character = 0 },
                    },
                };
                try locations.append(try loc.toJson(allocator));
            }

            const refs = try pr.getVarRefs(i, allocator);
            for (refs) |ref| {
                const ref_line: u32 = if (ref.line > 0) ref.line - 1 else 0;
                const loc = types.Location{
                    .uri = uri,
                    .range = .{
                        .start = .{ .line = ref_line, .character = 0 },
                        .end = .{ .line = ref_line, .character = 0 },
                    },
                };
                try locations.append(try loc.toJson(allocator));
            }

            try ctx.sendResponse(allocator, req_id, .{ .array = locations });
            return;
        }
    }

    // Search local variables in each procedure
    for (0..pr.num_procs) |pi| {
        const proc = pr.getProc(pi);
        for (0..proc.num_local_vars) |vi| {
            const local_var = pr.getProcVar(pi, vi);
            if (std.mem.eql(u8, local_var.name, word)) {
                if (include_declaration) {
                    const var_line: u32 = if (local_var.declared_line > 0) local_var.declared_line - 1 else 0;
                    const loc = types.Location{
                        .uri = uri,
                        .range = .{
                            .start = .{ .line = var_line, .character = 0 },
                            .end = .{ .line = var_line, .character = 0 },
                        },
                    };
                    try locations.append(try loc.toJson(allocator));
                }

                const refs = try pr.getProcVarRefs(pi, vi, allocator);
                for (refs) |ref| {
                    const ref_line: u32 = if (ref.line > 0) ref.line - 1 else 0;
                    const loc = types.Location{
                        .uri = uri,
                        .range = .{
                            .start = .{ .line = ref_line, .character = 0 },
                            .end = .{ .line = ref_line, .character = 0 },
                        },
                    };
                    try locations.append(try loc.toJson(allocator));
                }

                try ctx.sendResponse(allocator, req_id, .{ .array = locations });
                return;
            }
        }
    }

    // No match found
    try ctx.sendResponse(allocator, req_id, .{ .array = locations });
}
