const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");
const types = @import("../types.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, id: ?std.json.Value, params: std.json.Value) anyerror!void {
    const req_id = id orelse return;

    const uri = helpers.getTextDocumentUri(params) orelse {
        log.err("documentSymbol: missing textDocument.uri", .{});
        try ctx.sendResponse(allocator, req_id, .{ .array = std.json.Array.init(allocator) });
        return;
    };

    const doc = ctx.documents.getPtr(uri) orelse {
        log.debug("documentSymbol: unknown document {s}", .{uri});
        try ctx.sendResponse(allocator, req_id, .{ .array = std.json.Array.init(allocator) });
        return;
    };

    if (doc.parse_result == null) {
        try ctx.sendResponse(allocator, req_id, .{ .array = std.json.Array.init(allocator) });
        return;
    }
    const pr = &doc.parse_result.?;

    var symbols = std.json.Array.init(allocator);

    // Build procedure symbols
    for (0..pr.num_procs) |i| {
        const proc = pr.getProc(i);

        // Skip undefined (forward-declared only) procs
        if (!proc.defined) continue;

        const start_line = if (proc.start_line) |l| if (l > 0) l - 1 else 0 else 0;
        const end_line = if (proc.end_line) |l| if (l > 0) l - 1 else 0 else start_line;

        const range = types.Range{
            .start = .{ .line = start_line, .character = 0 },
            .end = .{ .line = end_line, .character = 0 },
        };

        // declared_line for selection range (the "procedure" keyword line)
        const decl_line: u32 = if (proc.declared_line > 0) proc.declared_line - 1 else 0;
        const selection_range = types.Range{
            .start = .{ .line = decl_line, .character = 0 },
            .end = .{ .line = decl_line, .character = 0 },
        };

        // Format flags as detail string
        var flags_buf: [128]u8 = undefined;
        const flags_str = proc.flags.format(&flags_buf);
        const detail: ?[]const u8 = if (!std.mem.eql(u8, flags_str, "(none)")) flags_str else null;

        // Build children: local variables of this procedure
        var children: ?[]const types.DocumentSymbol = null;
        if (proc.num_local_vars > 0) {
            var child_list = try std.ArrayListUnmanaged(types.DocumentSymbol).initCapacity(allocator, proc.num_local_vars);
            for (0..proc.num_local_vars) |vi| {
                const local_var = pr.getProcVar(i, vi);
                const var_line: u32 = if (local_var.declared_line > 0) local_var.declared_line - 1 else 0;
                const var_range = types.Range{
                    .start = .{ .line = var_line, .character = 0 },
                    .end = .{ .line = var_line, .character = 0 },
                };
                child_list.appendAssumeCapacity(.{
                    .name = local_var.name,
                    .detail = local_var.var_type.name(),
                    .kind = .Variable,
                    .range = var_range,
                    .selection_range = var_range,
                });
            }
            children = child_list.items;
        }

        const sym = types.DocumentSymbol{
            .name = proc.name,
            .detail = detail,
            .kind = .Function,
            .range = range,
            .selection_range = selection_range,
            .children = children,
        };
        try symbols.append(try sym.toJson(allocator));
    }

    // Build global variable symbols
    for (0..pr.num_vars) |i| {
        const v = pr.getVar(i);
        const var_line: u32 = if (v.declared_line > 0) v.declared_line - 1 else 0;
        const var_range = types.Range{
            .start = .{ .line = var_line, .character = 0 },
            .end = .{ .line = var_line, .character = 0 },
        };

        const sym = types.DocumentSymbol{
            .name = v.name,
            .detail = v.var_type.name(),
            .kind = .Variable,
            .range = var_range,
            .selection_range = var_range,
        };
        try symbols.append(try sym.toJson(allocator));
    }

    try ctx.sendResponse(allocator, req_id, .{ .array = symbols });
}
