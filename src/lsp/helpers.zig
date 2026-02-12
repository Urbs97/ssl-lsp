const std = @import("std");
const parser = @import("../parsing/parser.zig");

// JSON helper functions

pub fn getObject(val: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (val) {
        .object => |obj| if (obj.get(key)) |v| v else null,
        else => null,
    };
}

pub fn getString(val: std.json.Value, key: []const u8) ?[]const u8 {
    const v = switch (val) {
        .object => |obj| obj.get(key) orelse return null,
        else => return null,
    };
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn getInteger(val: std.json.Value, key: []const u8) ?i64 {
    const v = switch (val) {
        .object => |obj| obj.get(key) orelse return null,
        else => return null,
    };
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

pub fn getBool(val: std.json.Value, key: []const u8) ?bool {
    const v = switch (val) {
        .object => |obj| obj.get(key) orelse return null,
        else => return null,
    };
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

/// Extract textDocument.uri from params in one step.
pub fn getTextDocumentUri(params: std.json.Value) ?[]const u8 {
    const td = getObject(params, "textDocument") orelse return null;
    return getString(td, "uri");
}

pub const PositionParams = struct { line: i64, character: i64 };

/// Extract position.line and position.character from params in one step.
pub fn getPosition(params: std.json.Value) ?PositionParams {
    const pos = getObject(params, "position") orelse return null;
    const line = getInteger(pos, "line") orelse return null;
    const character = getInteger(pos, "character") orelse return null;
    return .{ .line = line, .character = character };
}

pub fn getArray(val: std.json.Value, key: []const u8) ?[]std.json.Value {
    const v = switch (val) {
        .object => |obj| obj.get(key) orelse return null,
        else => return null,
    };
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

/// Extract the identifier word at a given (line, character) position in text.
pub fn getWordAtPosition(text: []const u8, line: u32, character: u32) ?[]const u8 {
    // Find the target line
    var current_line: u32 = 0;
    var line_start: usize = 0;
    for (text, 0..) |ch, idx| {
        if (current_line == line) {
            line_start = idx;
            break;
        }
        if (ch == '\n') {
            current_line += 1;
        }
    } else {
        // If we exhausted text without finding the line (unless it's the last line)
        if (current_line != line) return null;
        line_start = text.len;
    }

    // Find line end
    var line_end: usize = line_start;
    while (line_end < text.len and text[line_end] != '\n') {
        line_end += 1;
    }

    const line_text = text[line_start..line_end];
    if (character >= line_text.len) return null;

    const char_idx = @as(usize, character);

    // Check that cursor is on an identifier character
    if (!isIdentChar(line_text[char_idx])) return null;

    // Scan left
    var start = char_idx;
    while (start > 0 and isIdentChar(line_text[start - 1])) {
        start -= 1;
    }

    // Scan right
    var end = char_idx + 1;
    while (end < line_text.len and isIdentChar(line_text[end])) {
        end += 1;
    }

    return line_text[start..end];
}

pub fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Extract the identifier prefix being typed at a given (line, character) position.
/// Only scans leftward from cursor position (characters before cursor, not after).
pub fn getWordPrefixAtPosition(text: []const u8, line: u32, character: u32) ?[]const u8 {
    // Find the target line
    var current_line: u32 = 0;
    var line_start: usize = 0;
    for (text, 0..) |ch, idx| {
        if (current_line == line) {
            line_start = idx;
            break;
        }
        if (ch == '\n') {
            current_line += 1;
        }
    } else {
        if (current_line != line) return null;
        line_start = text.len;
    }

    // Find line end
    var line_end: usize = line_start;
    while (line_end < text.len and text[line_end] != '\n') {
        line_end += 1;
    }

    const line_text = text[line_start..line_end];
    const char_idx = @as(usize, character);

    // Cursor at start of line or beyond — no prefix possible if at 0
    if (char_idx == 0) return null;

    // Clamp to line length (cursor can be at end of line)
    const end = @min(char_idx, line_text.len);
    if (end == 0) return null;

    // Check that the character just before cursor is an identifier character
    if (!isIdentChar(line_text[end - 1])) return null;

    // Scan left from cursor
    var start = end;
    while (start > 0 and isIdentChar(line_text[start - 1])) {
        start -= 1;
    }

    if (start == end) return null;
    return line_text[start..end];
}

/// Extract consecutive `///` doc comment lines immediately above a 1-indexed declaration line.
/// Returns the joined comment text (without the `///` prefix), or null if none found.
pub fn extractDocComment(allocator: std.mem.Allocator, text: []const u8, declared_line_1: u32) !?[]const u8 {
    if (declared_line_1 <= 1) return null;

    // Build an index of line start offsets
    var line_starts = std.ArrayListUnmanaged(usize){ .items = &.{}, .capacity = 0 };
    defer line_starts.deinit(allocator);
    try line_starts.append(allocator, 0);
    for (text, 0..) |ch, idx| {
        if (ch == '\n' and idx + 1 < text.len) {
            try line_starts.append(allocator, idx + 1);
        }
    }

    const target_line_0: usize = declared_line_1 - 1; // convert to 0-indexed

    // Collect /// lines going upward from the line above the declaration
    var comment_lines = std.ArrayListUnmanaged([]const u8){ .items = &.{}, .capacity = 0 };
    defer comment_lines.deinit(allocator);

    var cur = target_line_0;
    while (cur > 0) {
        cur -= 1;
        if (cur >= line_starts.items.len) break;
        const start = line_starts.items[cur];
        var end = start;
        while (end < text.len and text[end] != '\n') end += 1;
        const line_text = text[start..end];

        // Trim leading whitespace
        const trimmed = std.mem.trimLeft(u8, line_text, " \t");
        if (std.mem.startsWith(u8, trimmed, "///")) {
            // Strip the "///" prefix and one optional leading space
            var content = trimmed[3..];
            if (content.len > 0 and content[0] == ' ') content = content[1..];
            try comment_lines.append(allocator, content);
        } else {
            break;
        }
    }

    if (comment_lines.items.len == 0) return null;

    // Reverse to get top-to-bottom order and join with newlines
    std.mem.reverse([]const u8, comment_lines.items);
    var out: std.Io.Writer.Allocating = .init(allocator);
    for (comment_lines.items, 0..) |cline, i| {
        if (i > 0) try out.writer.writeByte('\n');
        try out.writer.writeAll(cline);
    }
    return out.written();
}

/// Format hover markdown for a procedure
pub fn formatProcHover(allocator: std.mem.Allocator, proc: parser.Procedure, proc_index: usize, pr: *const parser.ParseResult, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;

    // Code block header
    try w.writeAll("```ssl\n");

    // Flags prefix
    var flags_buf: [128]u8 = undefined;
    const flags_str = proc.flags.format(&flags_buf);
    if (!std.mem.eql(u8, flags_str, "(none)")) {
        try w.writeAll(flags_str);
        try w.writeByte(' ');
    }

    try w.writeAll("procedure ");
    try w.writeAll(proc.name);

    // Arguments — first num_args local variables are the parameters
    try w.writeByte('(');
    for (0..proc.num_args) |a| {
        if (a > 0) try w.writeAll(", ");
        const arg_var = pr.getProcVar(proc_index, a);
        try w.writeAll(arg_var.name);
    }
    try w.writeByte(')');
    try w.writeAll("\n```\n");

    // Doc comment
    if (try extractDocComment(allocator, text, proc.declared_line)) |doc_comment| {
        try w.writeAll("\n");
        try w.writeAll(doc_comment);
        try w.writeAll("\n\n");
    }

    // Details line
    if (proc.defined) {
        if (proc.start_line) |start| {
            if (proc.end_line) |end| {
                try w.print("Lines {d}\u{2013}{d}", .{ start, end });
            }
        }
    } else {
        try w.writeAll("Forward declaration");
    }

    if (proc.num_refs > 0) {
        if (proc.defined and proc.start_line != null) try w.writeAll(" \u{00b7} ");
        try w.print("{d} reference{s}", .{ proc.num_refs, if (proc.num_refs != 1) "s" else "" });
    }

    return out.written();
}

/// Format hover markdown for a variable
pub fn formatVarHover(allocator: std.mem.Allocator, v: parser.Variable, proc_name: ?[]const u8, pr: *const parser.ParseResult, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;

    // Code block header
    try w.writeAll("```ssl\n");
    try w.writeAll(v.var_type.name());
    try w.writeAll(" variable ");
    try w.writeAll(v.name);

    // Array notation
    if (v.array_len > 0) {
        try w.print("[{d}]", .{v.array_len});
    }

    // Initial value
    if (v.initialized) {
        if (v.value) |val| {
            switch (val) {
                .int => |n| try w.print(" := {d}", .{n}),
                .float => |f| try w.print(" := {d}", .{f}),
                .string => |offset| {
                    if (pr.getStringValue(offset)) |s| {
                        try w.print(" := \"{s}\"", .{s});
                    }
                },
            }
        }
    }

    try w.writeAll("\n```\n");

    // Doc comment
    if (try extractDocComment(allocator, text, v.declared_line)) |doc_comment| {
        try w.writeAll("\n");
        try w.writeAll(doc_comment);
        try w.writeAll("\n\n");
    }

    // Details
    if (proc_name) |pn| {
        try w.print("Local to `{s}`", .{pn});
        if (v.num_refs > 0) try w.writeAll(" \u{00b7} ");
    }

    if (v.num_refs > 0) {
        try w.print("{d} reference{s}", .{ v.num_refs, if (v.num_refs != 1) "s" else "" });
    }

    return out.written();
}
