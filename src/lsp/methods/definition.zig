const std = @import("std");
const Context = @import("../context.zig").Context;
const defines_mod = @import("../defines.zig");
const helpers = @import("../helpers.zig");
const types = @import("../types.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, id: ?std.json.Value, params: std.json.Value) anyerror!void {
    const req_id = id orelse return;

    const uri = helpers.getTextDocumentUri(params) orelse {
        log.err("definition: missing textDocument.uri", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };
    const pos = helpers.getPosition(params) orelse {
        log.err("definition: missing position params", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    const doc = ctx.documents.getPtr(uri) orelse {
        log.debug("definition: unknown document {s}", .{uri});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    // Check if cursor is on a #include directive → jump to the included file
    if (getIncludePath(doc.text, @intCast(pos.line), @intCast(pos.character))) |inc_path| {
        const resolved = helpers.resolveUriToPath(allocator, uri);
        defer resolved.deinit();
        const file_path = resolved.path;
        const include_dir = std.fs.path.dirname(file_path) orelse ".";
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (helpers.resolveIncludePath(&path_buf, include_dir, inc_path)) |full_path| {
            const target_uri = try helpers.pathToUri(allocator, full_path);
            const loc = types.Location{
                .uri = target_uri,
                .range = .{
                    .start = .{ .line = 0, .character = 0 },
                    .end = .{ .line = 0, .character = 0 },
                },
            };
            try ctx.sendResponse(allocator, req_id, try loc.toJson(allocator));
            return;
        }
    }

    const word = helpers.getWordAtPosition(doc.text, @intCast(pos.line), @intCast(pos.character)) orelse {
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    if (doc.parse_result) |*pr| {
        // Search procedures
        for (0..pr.num_procs) |i| {
            const proc = pr.getProc(i);
            if (std.ascii.eqlIgnoreCase(proc.name, word)) {
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
            if (std.ascii.eqlIgnoreCase(v.name, word)) {
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
                break;
            }
        }
    }

    // Search #define macros
    if (doc.defines) |*defs| {
        if (defs.lookupCaseInsensitive(word)) |def| {
            const def_uri = if (def.isLocal())
                uri
            else
                try helpers.pathToUri(allocator, def.file);
            const def_line: u32 = if (def.line > 0) def.line - 1 else 0;
            const name_len: u32 = @intCast(def.name.len);
            const loc = types.Location{
                .uri = def_uri,
                .range = .{
                    .start = .{ .line = def_line, .character = 0 },
                    .end = .{ .line = def_line, .character = name_len },
                },
            };
            try ctx.sendResponse(allocator, req_id, try loc.toJson(allocator));
            return;
        }
    }

    // No match found
    try ctx.sendResponse(allocator, req_id, .null);
}

/// Extract the #include path from a given line, if it is a #include "..." directive
/// and the cursor column falls within the directive (up to the closing quote).
fn getIncludePath(text: []const u8, target_line: u32, cursor_col: u32) ?[]const u8 {
    var current_line: u32 = 0;
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |raw_line| : (current_line += 1) {
        if (current_line != target_line) continue;
        const line_text = std.mem.trimLeft(u8, std.mem.trimRight(u8, raw_line, "\r"), " \t");
        if (!std.mem.startsWith(u8, line_text, "#include")) return null;
        const rest = std.mem.trimLeft(u8, line_text[8..], " \t");
        if (rest.len == 0 or rest[0] != '"') return null;
        const end_quote = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
        // Compute column of closing quote in the original (untrimmed) line
        const trimmed_raw = std.mem.trimRight(u8, raw_line, "\r");
        const leading_ws = trimmed_raw.len - line_text.len;
        const close_quote_col = leading_ws + (line_text.len - rest.len) + end_quote;
        if (cursor_col > close_quote_col) return null;
        return rest[1..end_quote];
    }
    return null;
}

