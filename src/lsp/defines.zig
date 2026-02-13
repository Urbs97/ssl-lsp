const std = @import("std");
const helpers = @import("helpers.zig");

pub const Define = struct {
    name: []const u8,
    params: ?[]const []const u8, // null = object-like; populated = function-like
    body: []const u8,
    file: []const u8, // source filename for hover display
    line: u32, // 1-indexed
    doc_comment: ?[]const u8, // preceding // comments
};

pub const DefineSet = struct {
    arena: std.heap.ArenaAllocator,
    defines: std.StringHashMapUnmanaged(Define),
    include_hash: u64 = 0, // hash of #include lines for cache invalidation

    pub fn init(child_allocator: std.mem.Allocator) DefineSet {
        return .{
            .arena = std.heap.ArenaAllocator.init(child_allocator),
            .defines = .empty,
        };
    }

    pub fn deinit(self: *DefineSet) void {
        // Free hash map metadata (buckets, etc.) allocated via the arena allocator,
        // then release all arena memory.
        self.defines.deinit(self.arena.allocator());
        self.arena.deinit();
    }

    pub fn lookup(self: *const DefineSet, name: []const u8) ?Define {
        return self.defines.get(name);
    }

    pub fn count(self: *const DefineSet) u32 {
        return self.defines.count();
    }
};

/// Extract all #define macros from a document and its #include'd headers.
/// The document_text is scanned for #include "path" directives, and each
/// included header is read from disk relative to include_dir.
/// If `previous` is provided and the set of #include lines hasn't changed,
/// header defines are copied from the previous set to avoid re-reading disk.
pub fn extractDefines(child_allocator: std.mem.Allocator, document_text: []const u8, include_dir: []const u8, previous: ?*const DefineSet) !DefineSet {
    var result = DefineSet.init(child_allocator);
    errdefer result.deinit();

    const allocator = result.arena.allocator();
    result.include_hash = computeIncludeHash(document_text);

    // If includes haven't changed, copy header defines from previous and only re-parse document
    if (previous) |prev| {
        if (prev.include_hash == result.include_hash) {
            // Copy header defines (file.len != 0) from previous set
            var it = prev.defines.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.file.len != 0) {
                    const copied = try copyDefine(allocator, entry.value_ptr.*);
                    try result.defines.put(allocator, copied.name, copied);
                }
            }
            // Parse only document-local defines (skip includes)
            try parseDefinesFromText(allocator, &result.defines, document_text, "", null, include_dir);
            return result;
        }
    }

    // Full extraction: parse document and follow includes
    var visited = std.StringHashMapUnmanaged(void){};
    defer visited.deinit(allocator);

    try parseDefinesFromText(allocator, &result.defines, document_text, "", &visited, include_dir);

    return result;
}

/// Parse #define directives from text content, recursively following #include directives.
/// When `visited` is null, #include directives are skipped (used for document-only parsing).
fn parseDefinesFromText(
    allocator: std.mem.Allocator,
    defines: *std.StringHashMapUnmanaged(Define),
    text: []const u8,
    filename: []const u8,
    visited: ?*std.StringHashMapUnmanaged(void),
    include_dir: []const u8,
) ParseError!void {
    var line_num: u32 = 0;
    var comment_lines = std.ArrayListUnmanaged([]const u8){};
    defer comment_lines.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |raw_line| {
        line_num += 1;
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Track comment lines for doc comments
        if (std.mem.startsWith(u8, trimmed, "//")) {
            var content = trimmed[2..];
            if (content.len > 0 and content[0] == ' ') content = content[1..];
            try comment_lines.append(allocator, content);
            continue;
        }

        // Handle #include "path"
        if (std.mem.startsWith(u8, trimmed, "#include")) {
            comment_lines.clearRetainingCapacity();
            if (visited) |v| {
                const rest = std.mem.trimLeft(u8, trimmed[8..], " \t");
                if (rest.len > 0 and rest[0] == '"') {
                    if (std.mem.indexOfScalarPos(u8, rest, 1, '"')) |end_quote| {
                        const inc_path = rest[1..end_quote];
                        try processInclude(allocator, defines, inc_path, v, include_dir);
                    }
                }
            }
            continue;
        }

        // Handle #define
        if (std.mem.startsWith(u8, trimmed, "#define")) {
            const rest = trimmed[7..];
            if (rest.len == 0 or (rest[0] != ' ' and rest[0] != '\t')) {
                comment_lines.clearRetainingCapacity();
                continue;
            }
            const after_define = std.mem.trimLeft(u8, rest, " \t");
            if (after_define.len == 0) {
                comment_lines.clearRetainingCapacity();
                continue;
            }

            // Extract macro name
            var name_end: usize = 0;
            while (name_end < after_define.len and helpers.isIdentChar(after_define[name_end])) {
                name_end += 1;
            }
            if (name_end == 0) {
                comment_lines.clearRetainingCapacity();
                continue;
            }

            const name = try allocator.dupe(u8, after_define[0..name_end]);
            const after_name = after_define[name_end..];

            // Determine if function-like: '(' immediately after name (no space)
            var params: ?[]const []const u8 = null;
            var body_start = after_name;

            if (after_name.len > 0 and after_name[0] == '(') {
                // Function-like macro
                if (std.mem.indexOfScalar(u8, after_name, ')')) |close_paren| {
                    const param_text = after_name[1..close_paren];
                    params = try parseParams(allocator, param_text);
                    body_start = std.mem.trimLeft(u8, after_name[close_paren + 1 ..], " \t");
                }
            } else {
                // Object-like: skip whitespace to get body
                body_start = std.mem.trimLeft(u8, after_name, " \t");
            }

            // Join continuation lines for the body
            const define_line = line_num; // capture start line before continuations
            var body_buf = std.ArrayListUnmanaged(u8){};
            defer body_buf.deinit(allocator);
            try body_buf.appendSlice(allocator, body_start);

            // Check for backslash continuation
            while (body_buf.items.len > 0 and body_buf.items[body_buf.items.len - 1] == '\\') {
                body_buf.items.len -= 1; // remove backslash
                // Trim trailing whitespace before the backslash
                while (body_buf.items.len > 0 and (body_buf.items[body_buf.items.len - 1] == ' ' or body_buf.items[body_buf.items.len - 1] == '\t')) {
                    body_buf.items.len -= 1;
                }
                if (line_iter.next()) |cont_raw| {
                    line_num += 1;
                    const cont_line = std.mem.trimRight(u8, cont_raw, "\r");
                    const cont_trimmed = std.mem.trim(u8, cont_line, " \t");
                    if (body_buf.items.len > 0) try body_buf.append(allocator, '\n');
                    try body_buf.appendSlice(allocator, cont_trimmed);
                } else break;
            }

            const body = try allocator.dupe(u8, body_buf.items);

            // Skip include guards: empty body + name ends with _H
            if (body.len == 0 and std.mem.endsWith(u8, name, "_H")) {
                comment_lines.clearRetainingCapacity();
                continue;
            }

            // Build doc comment
            var doc_comment: ?[]const u8 = null;
            if (comment_lines.items.len > 0) {
                var out: std.Io.Writer.Allocating = .init(allocator);
                for (comment_lines.items, 0..) |cline, i| {
                    if (i > 0) try out.writer.writeByte('\n');
                    try out.writer.writeAll(cline);
                }
                doc_comment = out.written();
            }

            const define = Define{
                .name = name,
                .params = params,
                .body = body,
                .file = filename,
                .line = define_line,
                .doc_comment = doc_comment,
            };

            // Later defines override earlier ones (same as builtins.zig dedup)
            try defines.put(allocator, name, define);
            comment_lines.clearRetainingCapacity();
            continue;
        }

        // Non-comment, non-directive line: reset comment accumulator
        if (trimmed.len > 0) {
            comment_lines.clearRetainingCapacity();
        }
    }
}

const ParseError = std.mem.Allocator.Error || std.fmt.BufPrintError || std.Io.Writer.Error;

/// Hash all #include lines in the text for cache invalidation.
fn computeIncludeHash(text: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "#include")) {
            hasher.update(trimmed);
            hasher.update("\n");
        }
    }
    return hasher.final();
}

/// Deep-copy a Define, duplicating all string fields into the given allocator.
fn copyDefine(allocator: std.mem.Allocator, def: Define) !Define {
    const name = try allocator.dupe(u8, def.name);
    const body = try allocator.dupe(u8, def.body);
    const file = try allocator.dupe(u8, def.file);
    const doc_comment = if (def.doc_comment) |dc| try allocator.dupe(u8, dc) else null;
    var params: ?[]const []const u8 = null;
    if (def.params) |src_params| {
        const new_params = try allocator.alloc([]const u8, src_params.len);
        for (src_params, 0..) |p, i| {
            new_params[i] = try allocator.dupe(u8, p);
        }
        params = new_params;
    }
    return .{
        .name = name,
        .params = params,
        .body = body,
        .file = file,
        .line = def.line,
        .doc_comment = doc_comment,
    };
}

/// Process a single #include directive by reading the file and parsing its defines.
fn processInclude(
    allocator: std.mem.Allocator,
    defines: *std.StringHashMapUnmanaged(Define),
    inc_path: []const u8,
    visited: *std.StringHashMapUnmanaged(void),
    include_dir: []const u8,
) ParseError!void {
    // Resolve include path (handles backslashes and case-insensitive matching)
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = helpers.resolveIncludePath(&path_buf, include_dir, inc_path) orelse return;

    // Check visited
    if (visited.get(full_path) != null) return;
    const path_dupe = try allocator.dupe(u8, full_path);
    try visited.put(allocator, path_dupe, {});

    // Read the file
    const content = std.fs.cwd().readFileAlloc(allocator, full_path, 1024 * 1024) catch return;

    // Use the included file's directory for resolving its own nested includes
    const nested_include_dir = std.fs.path.dirname(full_path) orelse include_dir;
    const nested_dir_dupe = try allocator.dupe(u8, nested_include_dir);

    try parseDefinesFromText(allocator, defines, content, path_dupe, visited, nested_dir_dupe);
}

/// Parse comma-separated parameter names from the text between ( and ).
fn parseParams(allocator: std.mem.Allocator, param_text: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, param_text, " \t");
    if (trimmed.len == 0) {
        return try allocator.alloc([]const u8, 0);
    }

    // Count params
    var count: usize = 1;
    for (trimmed) |ch| {
        if (ch == ',') count += 1;
    }

    const params = try allocator.alloc([]const u8, count);
    var idx: usize = 0;
    var start: usize = 0;
    for (trimmed, 0..) |ch, i| {
        if (ch == ',') {
            params[idx] = try allocator.dupe(u8, std.mem.trim(u8, trimmed[start..i], " \t"));
            idx += 1;
            start = i + 1;
        }
    }
    params[idx] = try allocator.dupe(u8, std.mem.trim(u8, trimmed[start..], " \t"));

    return params;
}

/// Format the detail string for a define, used in completion items.
/// Function-like: "#define name(x, y) body"
/// Object-like:   "#define NAME body"
pub fn formatDetail(allocator: std.mem.Allocator, def: Define) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    try w.writeAll("#define ");
    try w.writeAll(def.name);
    if (def.params) |params| {
        try w.writeByte('(');
        for (params, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(p);
        }
        try w.writeByte(')');
    }
    if (def.body.len > 0) {
        try w.writeByte(' ');
        // Flatten newlines and truncate long bodies for display
        const body_flat = try allocator.dupe(u8, def.body);
        for (body_flat) |*ch| {
            if (ch.* == '\n') ch.* = ' ';
        }
        if (body_flat.len > 80) {
            try w.writeAll(body_flat[0..77]);
            try w.writeAll("...");
        } else {
            try w.writeAll(body_flat);
        }
    }
    return out.written();
}

/// Format hover markdown for a define.
pub fn formatHover(allocator: std.mem.Allocator, def: Define) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;

    try w.writeAll("```c\n#define ");
    try w.writeAll(def.name);
    if (def.params) |params| {
        try w.writeByte('(');
        for (params, 0..) |p, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(p);
        }
        try w.writeByte(')');
    }
    if (def.body.len > 0) {
        try w.writeByte(' ');
        try w.writeAll(def.body);
    }
    try w.writeAll("\n```\n");

    if (def.doc_comment) |doc| {
        try w.writeByte('\n');
        try w.writeAll(doc);
        try w.writeByte('\n');
    }

    try w.print("\nDefined in {s}:{d}", .{ if (def.file.len == 0) "current file" else std.fs.path.basename(def.file), def.line });

    return out.written();
}

// ---- Tests ----

test "parse simple object-like define" {
    const allocator = std.testing.allocator;
    const text = "#define FOO 42\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("FOO").?;
    try std.testing.expectEqualStrings("FOO", def.name);
    try std.testing.expect(def.params == null);
    try std.testing.expectEqualStrings("42", def.body);
}

test "parse function-like define" {
    const allocator = std.testing.allocator;
    const text = "#define CALC(x, y) ((x) + (y))\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("CALC").?;
    try std.testing.expectEqualStrings("CALC", def.name);
    const params = def.params.?;
    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("x", params[0]);
    try std.testing.expectEqualStrings("y", params[1]);
    try std.testing.expectEqualStrings("((x) + (y))", def.body);
}

test "space before paren is object-like" {
    const allocator = std.testing.allocator;
    const text = "#define create_array_map (create_array(-1, 0))\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("create_array_map").?;
    try std.testing.expect(def.params == null);
    try std.testing.expectEqualStrings("(create_array(-1, 0))", def.body);
}

test "multi-line define with backslash continuation" {
    const allocator = std.testing.allocator;
    const text =
        \\#define MULTI(x) foo(x); \
        \\  bar(x)
        \\
    ;
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("MULTI").?;
    const params = def.params.?;
    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqualStrings("x", params[0]);
    try std.testing.expectEqualStrings("foo(x);\nbar(x)", def.body);
}

test "skip include guards" {
    const allocator = std.testing.allocator;
    const text = "#ifndef SFALL_H\n#define SFALL_H\n#define FOO 1\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    try std.testing.expect(defs.lookup("SFALL_H") == null);
    try std.testing.expect(defs.lookup("FOO") != null);
}

test "doc comment extraction" {
    const allocator = std.testing.allocator;
    const text =
        \\// This is a comment
        \\// about FOO
        \\#define FOO 42
        \\
    ;
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("FOO").?;
    try std.testing.expectEqualStrings("This is a comment\nabout FOO", def.doc_comment.?);
}

test "define with no params but parens in body" {
    const allocator = std.testing.allocator;
    const text = "#define map_first_run metarule(METARULE_TEST_FIRSTRUN, 0)\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("map_first_run").?;
    try std.testing.expect(def.params == null);
    try std.testing.expectEqualStrings("metarule(METARULE_TEST_FIRSTRUN, 0)", def.body);
}

test "function-like with zero args" {
    const allocator = std.testing.allocator;
    const text = "#define ZERO() (0)\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("ZERO").?;
    const params = def.params.?;
    try std.testing.expectEqual(@as(usize, 0), params.len);
    try std.testing.expectEqualStrings("(0)", def.body);
}

test "later defines override earlier" {
    const allocator = std.testing.allocator;
    const text = "#define FOO 1\n#define FOO 2\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("FOO").?;
    try std.testing.expectEqualStrings("2", def.body);
}

test "formatDetail object-like" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = "#define WORLDMAP (0x1)\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("WORLDMAP").?;
    const detail = try formatDetail(arena.allocator(), def);
    try std.testing.expectEqualStrings("#define WORLDMAP (0x1)", detail);
}

test "formatDetail function-like" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const text = "#define CALC(x, y) ((x) + (y))\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("CALC").?;
    const detail = try formatDetail(arena.allocator(), def);
    try std.testing.expectEqualStrings("#define CALC(x, y) ((x) + (y))", detail);
}

test "parse defines from real headers" {
    const allocator = std.testing.allocator;
    const text = "#include \"headers/sfall.h\"\n#include \"headers/define_lite.h\"\n#include \"headers/command_lite.h\"\n";
    var defs = try extractDefines(allocator, text, "test", null);
    defer defs.deinit();

    // Should find constants from sfall.h
    const worldmap = defs.lookup("WORLDMAP");
    if (worldmap) |def| {
        try std.testing.expectEqualStrings("(0x1)", def.body);
        try std.testing.expect(def.params == null);
    }

    // Should find function-like from sfall.h
    const create_list = defs.lookup("create_array_list");
    if (create_list) |def| {
        const params = def.params.?;
        try std.testing.expectEqual(@as(usize, 1), params.len);
        try std.testing.expectEqualStrings("size", params[0]);
    }

    // Should find function-like from command_lite.h
    const get_armor = defs.lookup("get_armor");
    if (get_armor) |def| {
        const params = def.params.?;
        try std.testing.expectEqual(@as(usize, 1), params.len);
        try std.testing.expectEqualStrings("cr", params[0]);
    }

    // Should find constants from define_lite.h
    const start = defs.lookup("start_proc");
    if (start) |def| {
        try std.testing.expect(def.params == null);
        try std.testing.expectEqualStrings("(1)", def.body);
    }

    // Should skip include guards
    try std.testing.expect(defs.lookup("SFALL_H") == null);
    try std.testing.expect(defs.lookup("DEFINE_H") == null);
    try std.testing.expect(defs.lookup("COMMAND_H") == null);

    // Should have a reasonable number of defines
    try std.testing.expect(defs.count() > 50);
}

test "cache reuses header defines when includes unchanged" {
    const allocator = std.testing.allocator;
    const text1 = "#include \"headers/sfall.h\"\n#define LOCAL1 1\n";
    var defs1 = try extractDefines(allocator, text1, "test", null);
    defer defs1.deinit();

    // Verify initial state
    try std.testing.expect(defs1.lookup("WORLDMAP") != null);
    try std.testing.expect(defs1.lookup("LOCAL1") != null);
    try std.testing.expect(defs1.include_hash != 0);

    // Same includes, different local define — should reuse cached header defines
    const text2 = "#include \"headers/sfall.h\"\n#define LOCAL2 2\n";
    var defs2 = try extractDefines(allocator, text2, "test", &defs1);
    defer defs2.deinit();

    // Header defines should still be present (copied from cache)
    try std.testing.expect(defs2.lookup("WORLDMAP") != null);
    // Old local define should be gone, new one present
    try std.testing.expect(defs2.lookup("LOCAL1") == null);
    try std.testing.expect(defs2.lookup("LOCAL2") != null);
    // Include hashes should match
    try std.testing.expectEqual(defs1.include_hash, defs2.include_hash);
}

test "cache invalidated when includes change" {
    const allocator = std.testing.allocator;
    const text1 = "#include \"headers/sfall.h\"\n#define LOCAL1 1\n";
    var defs1 = try extractDefines(allocator, text1, "test", null);
    defer defs1.deinit();

    // Different includes — cache should be invalidated
    const text2 = "#include \"headers/define_lite.h\"\n#define LOCAL1 1\n";
    var defs2 = try extractDefines(allocator, text2, "test", &defs1);
    defer defs2.deinit();

    // Include hashes should differ
    try std.testing.expect(defs1.include_hash != defs2.include_hash);
    // Should have defines from the new header
    try std.testing.expect(defs2.lookup("start_proc") != null);
}
