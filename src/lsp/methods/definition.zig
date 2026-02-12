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
    if (getIncludePath(doc.text, @intCast(pos.line))) |inc_path| {
        const file_path = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
        const include_dir = std.fs.path.dirname(file_path) orelse ".";
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}{c}{s}", .{ include_dir, std.fs.path.sep, inc_path }) catch {
            try ctx.sendResponse(allocator, req_id, .null);
            return;
        };
        // Verify the file exists
        std.fs.cwd().access(full_path, .{}) catch {
            try ctx.sendResponse(allocator, req_id, .null);
            return;
        };
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

    if (doc.parse_result == null) {
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    }
    const pr = &doc.parse_result.?;

    const word = helpers.getWordAtPosition(doc.text, @intCast(pos.line), @intCast(pos.character)) orelse {
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

    // Search local variables in the enclosing procedure only
    const cursor_line: u32 = @intCast(pos.line + 1); // parser lines are 1-indexed
    for (0..pr.num_procs) |pi| {
        const proc = pr.getProc(pi);
        const start = proc.start_line orelse continue;
        const end = proc.end_line orelse continue;
        if (cursor_line >= start and cursor_line <= end) {
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
            break;
        }
    }

    // Search #define macros
    if (doc.defines) |*defs| {
        if (defs.lookup(word)) |def| {
            const def_uri = if (std.mem.eql(u8, def.file, "current file"))
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

/// Extract the #include path from a given line, if it is a #include "..." directive.
fn getIncludePath(text: []const u8, line: u32) ?[]const u8 {
    var current_line: u32 = 0;
    var line_start: usize = 0;
    for (text, 0..) |ch, idx| {
        if (current_line == line) {
            line_start = idx;
            break;
        }
        if (ch == '\n') current_line += 1;
    } else {
        if (current_line != line) return null;
        line_start = text.len;
    }

    var line_end: usize = line_start;
    while (line_end < text.len and text[line_end] != '\n') line_end += 1;

    const line_text = std.mem.trimLeft(u8, text[line_start..line_end], " \t");
    if (!std.mem.startsWith(u8, line_text, "#include")) return null;
    const rest = std.mem.trimLeft(u8, line_text[8..], " \t");
    if (rest.len == 0 or rest[0] != '"') return null;
    const end_quote = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
    return rest[1..end_quote];
}
