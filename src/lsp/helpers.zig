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

pub const CallContext = struct {
    func_name: []const u8,
    active_param: u32,
};

/// Convert (line, character) to an absolute byte offset in text.
fn lineCharToOffset(text: []const u8, line: u32, character: u32) ?usize {
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
    const offset = line_start + character;
    if (offset > text.len) return null;
    return offset;
}

/// Determine the function name and active parameter index at a cursor position inside a call.
/// Returns null if the cursor is not inside a function call's parentheses.
pub fn getCallContext(text: []const u8, line: u32, character: u32) ?CallContext {
    const cursor = lineCharToOffset(text, line, character) orelse return null;

    var depth: u32 = 0;
    var comma_count: u32 = 0;
    var i: usize = cursor;

    while (i > 0) {
        i -= 1;
        const ch = text[i];

        // Skip string literals (scan backwards past opening quote, handling escapes)
        if (ch == '"') {
            if (i > 0) {
                i -= 1;
                while (true) {
                    // Scan backwards for the next quote
                    while (i > 0 and text[i] != '"') : (i -= 1) {}
                    // Count preceding backslashes
                    var bs: usize = 0;
                    while (bs < i and text[i - 1 - bs] == '\\') : (bs += 1) {}
                    if (bs % 2 == 0) break; // Even backslashes → unescaped quote → done
                    // Odd backslashes → escaped quote → keep scanning
                    if (i == 0) break;
                    i -= 1;
                }
            }
            continue;
        }

        if (ch == ')') {
            depth += 1;
        } else if (ch == '(') {
            if (depth > 0) {
                depth -= 1;
            } else {
                // Found the target opening paren — extract function name
                var name_end = i;
                // Skip whitespace before '('
                while (name_end > 0 and (text[name_end - 1] == ' ' or text[name_end - 1] == '\t')) {
                    name_end -= 1;
                }
                if (name_end == 0 or !isIdentChar(text[name_end - 1])) return null;

                var name_start = name_end;
                while (name_start > 0 and isIdentChar(text[name_start - 1])) {
                    name_start -= 1;
                }

                if (name_start == name_end) return null;

                return .{
                    .func_name = text[name_start..name_end],
                    .active_param = comma_count,
                };
            }
        } else if (ch == ',' and depth == 0) {
            comma_count += 1;
        }
    }

    return null;
}

/// Extract individual parameter strings from an opcode signature like "int random(int min, int max)".
/// Returns null for property-style opcodes (no parentheses).
pub fn parseSignatureParams(allocator: std.mem.Allocator, signature: []const u8) ?[]const []const u8 {
    const open = std.mem.indexOfScalar(u8, signature, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, signature, ')') orelse return null;
    if (close <= open + 1) {
        // Empty parens like "void func()" — zero params
        const empty = allocator.alloc([]const u8, 0) catch return null;
        return empty;
    }

    const inner = signature[open + 1 .. close];

    // Count commas at depth 0 to determine number of params
    var count: usize = 1;
    var d: u32 = 0;
    for (inner) |ch| {
        if (ch == '(') d += 1 else if (ch == ')') {
            d -|= 1;
        } else if (ch == ',' and d == 0) count += 1;
    }

    const params = allocator.alloc([]const u8, count) catch return null;
    var idx: usize = 0;
    d = 0;
    var start: usize = 0;
    for (inner, 0..) |ch, ci| {
        if (ch == '(') d += 1 else if (ch == ')') {
            d -|= 1;
        } else if (ch == ',' and d == 0) {
            params[idx] = std.mem.trim(u8, inner[start..ci], " \t");
            idx += 1;
            start = ci + 1;
        }
    }
    params[idx] = std.mem.trim(u8, inner[start..], " \t");

    return params;
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

/// Construct a file:// URI from an absolute filesystem path.
/// Percent-encodes characters that are not valid in URI paths (spaces, #, etc.).
pub fn pathToUri(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try out.writer.writeAll("file://");
    try (std.Uri.Component{ .raw = path }).formatPath(&out.writer);
    return out.written();
}

pub const WordOccurrence = struct {
    line: u32,
    character: u32,
};

/// Find all whole-word occurrences of `word` in `text`, returning line/character positions.
/// A "whole word" match means the character before and after are not identifier characters.
pub fn findWordOccurrences(allocator: std.mem.Allocator, text: []const u8, word: []const u8) ![]WordOccurrence {
    var results = std.ArrayListUnmanaged(WordOccurrence){};
    defer results.deinit(allocator);

    var line_num: u32 = 0;
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        var col: usize = 0;
        while (col + word.len <= line.len) {
            if (std.mem.eql(u8, line[col .. col + word.len], word)) {
                const before_ok = col == 0 or !isIdentChar(line[col - 1]);
                const after_ok = col + word.len >= line.len or !isIdentChar(line[col + word.len]);
                if (before_ok and after_ok) {
                    try results.append(allocator, .{ .line = line_num, .character = @intCast(col) });
                }
            }
            col += 1;
        }
        line_num += 1;
    }

    return try allocator.dupe(WordOccurrence, results.items);
}

test "getCallContext basic" {
    const text = "random(1, 2)";
    // Cursor after opening paren: random(|
    const ctx1 = getCallContext(text, 0, 7).?;
    try std.testing.expectEqualStrings("random", ctx1.func_name);
    try std.testing.expectEqual(@as(u32, 0), ctx1.active_param);

    // Cursor after comma: random(1, |
    const ctx2 = getCallContext(text, 0, 10).?;
    try std.testing.expectEqualStrings("random", ctx2.func_name);
    try std.testing.expectEqual(@as(u32, 1), ctx2.active_param);
}

test "getCallContext nested parens" {
    const text = "foo(bar(1, 2), )";
    // Cursor at position 15 → inside foo's second param: foo(bar(1, 2), |)
    const ctx = getCallContext(text, 0, 15).?;
    try std.testing.expectEqualStrings("foo", ctx.func_name);
    try std.testing.expectEqual(@as(u32, 1), ctx.active_param);
}

test "getCallContext string with comma" {
    const text =
        \\foo("a,b", )
    ;
    // Cursor at position 11 → second param: foo("a,b", |)
    const ctx = getCallContext(text, 0, 11).?;
    try std.testing.expectEqualStrings("foo", ctx.func_name);
    try std.testing.expectEqual(@as(u32, 1), ctx.active_param);
}

test "getCallContext escaped quote in string" {
    const text =
        \\foo("a\"b", x)
    ;
    // Cursor at position 13 → second param: foo("a\"b", x|)
    const ctx = getCallContext(text, 0, 13).?;
    try std.testing.expectEqualStrings("foo", ctx.func_name);
    try std.testing.expectEqual(@as(u32, 1), ctx.active_param);
}

test "getCallContext escaped backslash before quote" {
    const text =
        \\foo("a\\", x)
    ;
    // Cursor at position 12 → second param: foo("a\\", x|)
    const ctx = getCallContext(text, 0, 12).?;
    try std.testing.expectEqualStrings("foo", ctx.func_name);
    try std.testing.expectEqual(@as(u32, 1), ctx.active_param);
}

test "getCallContext multiline" {
    const text = "foo(\n  1,\n  2)";
    // Cursor on line 2, character 2 → second param
    const ctx = getCallContext(text, 2, 2).?;
    try std.testing.expectEqualStrings("foo", ctx.func_name);
    try std.testing.expectEqual(@as(u32, 1), ctx.active_param);
}

test "getCallContext no paren returns null" {
    const text = "hello world";
    try std.testing.expectEqual(@as(?CallContext, null), getCallContext(text, 0, 5));
}

test "parseSignatureParams basic" {
    const params = parseSignatureParams(std.testing.allocator, "int random(int min, int max)").?;
    defer std.testing.allocator.free(params);
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("int min", params[0]);
    try std.testing.expectEqualStrings("int max", params[1]);
}

test "parseSignatureParams no paren property" {
    try std.testing.expectEqual(@as(?[]const []const u8, null), parseSignatureParams(std.testing.allocator, "int cur_hp"));
}

test "parseSignatureParams zero args" {
    const params = parseSignatureParams(std.testing.allocator, "void cleanup()").?;
    defer std.testing.allocator.free(params);
    try std.testing.expectEqual(@as(usize, 0), params.len);
}
