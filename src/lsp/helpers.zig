const std = @import("std");
const parser = @import("../parsing/parser.zig");

const log = std.log.scoped(.server);

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

/// Resolve an include path relative to a base directory, handling Windows backslashes.
/// Returns the resolved path in `buf`, or null if the file cannot be found.
/// Falls back to case-insensitive matching for each path component (needed for
/// Windows-originated SSL scripts running on case-sensitive Linux filesystems).
pub fn resolveIncludePath(buf: *[std.fs.max_path_bytes]u8, base_dir: []const u8, raw_inc_path: []const u8) ?[]const u8 {
    // Normalize backslashes to forward slashes
    var inc_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inc_path = normalizeBackslashes(&inc_buf, raw_inc_path);

    // Build the full path: base_dir/inc_path
    // Strip trailing separator to avoid double-slash in joined path
    const trimmed_dir = if (base_dir.len > 1 and base_dir[base_dir.len - 1] == std.fs.path.sep)
        base_dir[0 .. base_dir.len - 1]
    else
        base_dir;
    const full_path = std.fmt.bufPrint(buf, "{s}{c}{s}", .{ trimmed_dir, std.fs.path.sep, inc_path }) catch return null;

    // Fast path: exact match
    std.fs.cwd().access(full_path, .{}) catch {
        // Slow path: case-insensitive component-by-component resolution
        return resolveCaseInsensitive(buf, full_path);
    };
    return full_path;
}

/// Walk each component of `path` from the root, matching directory entries
/// case-insensitively. Returns the resolved real path in `buf`, or null if
/// no match is found.
fn resolveCaseInsensitive(buf: *[std.fs.max_path_bytes]u8, path: []const u8) ?[]const u8 {
    // Normalize away ".." and "." segments first
    var norm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const normalized = normalizePath(&norm_buf, path);

    // Split into components (skip leading '/' — we'll reconstruct from root)
    const relative = if (normalized.len > 0 and normalized[0] == '/') normalized[1..] else normalized;
    if (relative.len == 0) return null;

    // Build resolved path in buf, starting from root "/"
    var out_len: usize = 0;

    var comp_iter = std.mem.splitScalar(u8, relative, '/');
    while (comp_iter.next()) |component| {
        if (component.len == 0) continue;

        // Current directory to search in
        const search_dir = if (out_len == 0) "/" else buf[0..out_len];

        // Try exact match first
        const exact_len = out_len + 1 + component.len;
        if (exact_len <= buf.len) {
            buf[out_len] = '/';
            @memcpy(buf[out_len + 1 ..][0..component.len], component);
            std.fs.cwd().access(buf[0..exact_len], .{}) catch {
                // Exact match failed — scan directory for case-insensitive match
                buf[out_len] = '/';
                if (findCaseInsensitiveEntry(buf, out_len + 1, search_dir, component)) |name_len| {
                    out_len += 1 + name_len;
                    continue;
                }
                return null;
            };
            out_len = exact_len;
            continue;
        }
        return null;
    }

    if (out_len == 0) return null;

    // Verify the final path actually exists
    std.fs.cwd().access(buf[0..out_len], .{}) catch return null;
    return buf[0..out_len];
}

/// Normalize a path by resolving "." and ".." segments in place.
fn normalizePath(buf: *[std.fs.max_path_bytes]u8, path: []const u8) []const u8 {
    var components: [256][]const u8 = undefined;
    var count: usize = 0;
    const is_absolute = path.len > 0 and path[0] == '/';

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |comp| {
        if (comp.len == 0 or std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (count > 0) count -= 1;
            continue;
        }
        if (count >= components.len) {
            log.warn("normalizePath: path has more than {d} components, truncating", .{components.len});
            break;
        }
        components[count] = comp;
        count += 1;
    }

    // Reconstruct
    var out_len: usize = 0;
    if (is_absolute) {
        buf[0] = '/';
        out_len = 1;
    }
    for (components[0..count], 0..) |comp, i| {
        if (i > 0 or is_absolute) {
            if (out_len > 1 or !is_absolute) {
                buf[out_len] = '/';
                out_len += 1;
            }
        }
        @memcpy(buf[out_len..][0..comp.len], comp);
        out_len += comp.len;
    }
    return buf[0..out_len];
}

/// Scan a directory for an entry matching `name` case-insensitively.
/// Writes the real entry name directly into `buf` at the given `buf_offset`.
/// Returns the length of the entry name written, or null if no match found.
fn findCaseInsensitiveEntry(buf: *[std.fs.max_path_bytes]u8, buf_offset: usize, dir_path: []const u8, name: []const u8) ?usize {
    const dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return null;
    // dir is a value type in Zig's std, but we need to iterate — use a mutable copy
    var mutable_dir = dir;
    defer mutable_dir.close();

    var it = mutable_dir.iterate();
    while (it.next() catch return null) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.name, name)) {
            if (buf_offset + entry.name.len > buf.len) return null;
            @memcpy(buf[buf_offset..][0..entry.name.len], entry.name);
            return entry.name.len;
        }
    }
    return null;
}

/// Replace backslashes with forward slashes for cross-platform path compatibility.
fn normalizeBackslashes(buf: []u8, path: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, path, '\\') == null) return path;
    const len = @min(path.len, buf.len);
    @memcpy(buf[0..len], path[0..len]);
    std.mem.replaceScalar(u8, buf[0..len], '\\', '/');
    return buf[0..len];
}

/// Convert a file:// URI to a filesystem path, decoding percent-encoded characters.
/// Always returns an owned allocation that the caller must free.
pub fn uriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]const u8 {
    const encoded = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
    const component = std.Uri.Component{ .percent_encoded = encoded };
    return std.fmt.allocPrint(allocator, "{f}", .{std.fmt.alt(component, .formatRaw)});
}

pub const ResolvedPath = struct {
    path: []const u8,
    owned: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: ResolvedPath) void {
        if (self.owned) |o| self.allocator.free(o);
    }
};

/// Resolve a file:// URI to a filesystem path, with fallback to stripping the scheme prefix.
pub fn resolveUriToPath(allocator: std.mem.Allocator, uri: []const u8) ResolvedPath {
    const owned = uriToPath(allocator, uri) catch null;
    const path = owned orelse if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
    return .{ .path = path, .owned = owned, .allocator = allocator };
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

/// A range of bytes within a line that represent actual code (not comments or strings).
pub const CodeRange = struct {
    start: usize,
    end: usize,
};

/// Compute byte ranges within a line that are "code" — not inside comments or string literals.
/// `in_block_comment` tracks whether we are inside a `/* */` block comment from a previous line.
/// Returns the updated block-comment state for the next line.
pub fn computeCodeRanges(line: []const u8, in_block_comment: bool, ranges: *std.ArrayListUnmanaged(CodeRange), allocator: std.mem.Allocator) !bool {
    var in_block = in_block_comment;
    var i: usize = 0;
    var code_start: ?usize = if (!in_block) @as(usize, 0) else null;

    while (i < line.len) {
        if (in_block) {
            // Look for end of block comment
            if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '/') {
                i += 2;
                in_block = false;
                code_start = i;
            } else {
                i += 1;
            }
        } else {
            // Line comment: rest of line is not code
            if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '/') {
                if (code_start) |cs| {
                    if (i > cs) try ranges.append(allocator, .{ .start = cs, .end = i });
                }
                return in_block; // rest of line is comment
            }
            // Block comment start
            if (i + 1 < line.len and line[i] == '/' and line[i + 1] == '*') {
                if (code_start) |cs| {
                    if (i > cs) try ranges.append(allocator, .{ .start = cs, .end = i });
                }
                code_start = null;
                in_block = true;
                i += 2;
                continue;
            }
            // String literal
            if (line[i] == '"') {
                // Include the part before the string as code, but not the string itself
                // Actually, we want identifiers inside strings to NOT match, so the string
                // content is excluded from code ranges.
                if (code_start) |cs| {
                    if (i > cs) try ranges.append(allocator, .{ .start = cs, .end = i });
                }
                i += 1; // skip opening quote
                while (i < line.len) {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        i += 2; // skip escaped character
                    } else if (line[i] == '"') {
                        i += 1; // skip closing quote
                        break;
                    } else {
                        i += 1;
                    }
                }
                code_start = i;
                continue;
            }
            i += 1;
        }
    }

    // Close any remaining code range
    if (code_start) |cs| {
        if (line.len > cs) try ranges.append(allocator, .{ .start = cs, .end = line.len });
    }

    return in_block;
}

/// Check if a match at `pos` with length `len` is fully within any code range.
fn isInCodeRange(ranges: []const CodeRange, pos: usize, len: usize) bool {
    for (ranges) |r| {
        if (pos >= r.start and pos + len <= r.end) return true;
    }
    return false;
}

/// Case-insensitive substring search starting at `start`.
fn indexOfPosIgnoreCase(haystack: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return start;
    if (start + needle.len > haystack.len) return null;
    var i = start;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// Find all whole-word occurrences of `word` in `text`, returning line/character positions.
/// A "whole word" match means the character before and after are not identifier characters.
/// Matches inside comments (`//`, `/* */`) and string literals (`"..."`) are excluded.
/// Matching is case-insensitive.
pub fn findWordOccurrences(allocator: std.mem.Allocator, text: []const u8, word: []const u8) ![]WordOccurrence {
    var results = std.ArrayListUnmanaged(WordOccurrence){};
    defer results.deinit(allocator);

    var code_ranges = std.ArrayListUnmanaged(CodeRange){};
    defer code_ranges.deinit(allocator);

    var in_block_comment = false;
    var line_num: u32 = 0;
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");

        code_ranges.clearRetainingCapacity();
        in_block_comment = try computeCodeRanges(line, in_block_comment, &code_ranges, allocator);

        var col: usize = 0;
        while (indexOfPosIgnoreCase(line, col, word)) |match_pos| {
            const before_ok = match_pos == 0 or !isIdentChar(line[match_pos - 1]);
            const after_ok = match_pos + word.len >= line.len or !isIdentChar(line[match_pos + word.len]);
            if (before_ok and after_ok and isInCodeRange(code_ranges.items, match_pos, word.len)) {
                try results.append(allocator, .{ .line = line_num, .character = @intCast(match_pos) });
            }
            col = match_pos + 1;
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

test "uriToPath decodes percent-encoded characters" {
    const path = try uriToPath(std.testing.allocator, "file:///home/user/my%20project/file.ssl");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/my project/file.ssl", path);
}

test "uriToPath with no encoding" {
    const path = try uriToPath(std.testing.allocator, "file:///home/user/project/file.ssl");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/home/user/project/file.ssl", path);
}

test "resolveIncludePath case-insensitive fallback" {
    // Create a temp directory structure: /tmp/ssl_test_ci/HEADERS/SCENEPID.H
    const base = "/tmp/ssl_test_ci";
    std.fs.cwd().makePath(base ++ "/HEADERS") catch {};
    defer std.fs.cwd().deleteTree(base) catch {};

    // Create test file
    {
        const f = std.fs.cwd().createFile(base ++ "/HEADERS/SCENEPID.H", .{}) catch return;
        f.close();
    }

    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // Exact case should work
    const exact = resolveIncludePath(&buf, base, "HEADERS/SCENEPID.H");
    try std.testing.expect(exact != null);

    // Wrong case should also resolve via case-insensitive fallback
    var buf2: [std.fs.max_path_bytes]u8 = undefined;
    const ci = resolveIncludePath(&buf2, base, "headers/ScenePid.h");
    try std.testing.expect(ci != null);

    // Both should point to the same actual file
    if (exact) |e| {
        if (ci) |c| {
            try std.testing.expectEqualStrings(e, c);
        }
    }
}

test "resolveIncludePath case-insensitive with dotdot" {
    // Create: /tmp/ssl_test_ci2/HEADERS/SCENEPID.H
    const base = "/tmp/ssl_test_ci2";
    std.fs.cwd().makePath(base ++ "/HEADERS") catch {};
    std.fs.cwd().makePath(base ++ "/MAPS") catch {};
    defer std.fs.cwd().deleteTree(base) catch {};

    {
        const f = std.fs.cwd().createFile(base ++ "/HEADERS/SCENEPID.H", .{}) catch return;
        f.close();
    }

    // Resolve "..\headers\ScenePid.h" from the MAPS directory (simulating DEFINE.H's include
    // being resolved from the included file's directory)
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const result = resolveIncludePath(&buf, base ++ "/HEADERS", "..\\headers\\ScenePid.h");
    try std.testing.expect(result != null);
    // Should contain HEADERS/SCENEPID.H (the real casing)
    try std.testing.expect(std.mem.endsWith(u8, result.?, "/HEADERS/SCENEPID.H"));
}

test "normalizePath resolves dotdot" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const result = normalizePath(&buf, "/foo/bar/../baz/./qux");
    try std.testing.expectEqualStrings("/foo/baz/qux", result);
}

test "normalizePath absolute simple" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const result = normalizePath(&buf, "/a/b/c");
    try std.testing.expectEqualStrings("/a/b/c", result);
}

test "findWordOccurrences skips line comments" {
    const allocator = std.testing.allocator;
    const text = "FOO + BAR // FOO in comment\nFOO again";
    const results = try findWordOccurrences(allocator, text, "FOO");
    defer allocator.free(results);
    // Should find FOO at line 0 col 0 and line 1 col 0, but NOT the one in the comment
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u32, 0), results[0].line);
    try std.testing.expectEqual(@as(u32, 0), results[0].character);
    try std.testing.expectEqual(@as(u32, 1), results[1].line);
    try std.testing.expectEqual(@as(u32, 0), results[1].character);
}

test "findWordOccurrences skips block comments" {
    const allocator = std.testing.allocator;
    const text = "FOO /* FOO */ FOO";
    const results = try findWordOccurrences(allocator, text, "FOO");
    defer allocator.free(results);
    // Should find FOO at col 0 and col 14, but NOT the one inside /* */
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u32, 0), results[0].character);
    try std.testing.expectEqual(@as(u32, 14), results[1].character);
}

test "findWordOccurrences skips multi-line block comments" {
    const allocator = std.testing.allocator;
    const text = "FOO /* start\nFOO inside\nend */ FOO";
    const results = try findWordOccurrences(allocator, text, "FOO");
    defer allocator.free(results);
    // Should find FOO at line 0 col 0 and line 2 col 7, but not the ones in the block comment
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u32, 0), results[0].line);
    try std.testing.expectEqual(@as(u32, 0), results[0].character);
    try std.testing.expectEqual(@as(u32, 2), results[1].line);
    try std.testing.expectEqual(@as(u32, 7), results[1].character);
}

test "findWordOccurrences skips string literals" {
    const allocator = std.testing.allocator;
    const text =
        \\FOO + "FOO" + FOO
    ;
    const results = try findWordOccurrences(allocator, text, "FOO");
    defer allocator.free(results);
    // Should find FOO at col 0 and col 14, but NOT the one inside the string
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u32, 0), results[0].character);
    try std.testing.expectEqual(@as(u32, 14), results[1].character);
}

test "findWordOccurrences handles escaped quotes in strings" {
    const allocator = std.testing.allocator;
    const text =
        \\FOO + "FOO\"FOO" + FOO
    ;
    const results = try findWordOccurrences(allocator, text, "FOO");
    defer allocator.free(results);
    // Line is: FOO + "FOO\"FOO" + FOO
    // String spans col 6..15 (inclusive), last FOO at col 19
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqual(@as(u32, 0), results[0].character);
    try std.testing.expectEqual(@as(u32, 19), results[1].character);
}
