const std = @import("std");
const helpers = @import("helpers.zig");

const log = std.log.scoped(.server);

pub const Define = struct {
    name: []const u8,
    params: ?[]const []const u8, // null = object-like; populated = function-like
    body: []const u8,
    file: []const u8, // source filename for hover display
    line: u32, // 1-indexed
    doc_comment: ?[]const u8, // preceding // comments
};

pub const FileMtime = struct {
    path: []const u8,
    mtime: i128,
};

pub const DefineSet = struct {
    arena: std.heap.ArenaAllocator,
    defines: std.StringHashMapUnmanaged(Define),
    include_hash: u64 = 0, // hash of #include lines for cache invalidation
    file_mtimes: std.ArrayListUnmanaged(FileMtime) = .empty,

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

    /// Look up a define by name, falling back to case-insensitive matching.
    pub fn lookupCaseInsensitive(self: *const DefineSet, name: []const u8) ?Define {
        // Try exact match first (fast path)
        if (self.defines.get(name)) |def| return def;
        // Fall back to linear scan with case-insensitive comparison
        var it = self.defines.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
        }
        return null;
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

    // If includes haven't changed and header files haven't been modified, reuse cached defines
    if (previous) |prev| {
        if (prev.include_hash == result.include_hash and mtimesStillValid(prev.file_mtimes.items)) {
            // Copy header defines (file.len != 0) from previous set
            var it = prev.defines.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.file.len != 0) {
                    const copied = try copyDefine(allocator, entry.value_ptr.*);
                    try result.defines.put(allocator, copied.name, copied);
                }
            }
            // Copy file mtimes from previous set
            for (prev.file_mtimes.items) |entry| {
                try result.file_mtimes.append(allocator, .{
                    .path = try allocator.dupe(u8, entry.path),
                    .mtime = entry.mtime,
                });
            }
            // Parse only document-local defines (skip includes)
            try parseDefinesFromText(allocator, &result.defines, document_text, "", null, include_dir, null);
            return result;
        }
    }

    // Full extraction: parse document and follow includes
    var visited = std.StringHashMapUnmanaged(void){};
    defer visited.deinit(allocator);

    try parseDefinesFromText(allocator, &result.defines, document_text, "", &visited, include_dir, &result.file_mtimes);

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
    file_mtimes: ?*std.ArrayListUnmanaged(FileMtime),
) ParseError!void {
    var line_num: u32 = 0;
    var comment_lines = std.ArrayListUnmanaged([]const u8){};
    defer comment_lines.deinit(allocator);
    var last_ifndef: ?[]const u8 = null; // track #ifndef for include guard detection

    // Conditional compilation tracking: skip defines inside #else/#elif branches
    var cond_depth: u32 = 0;
    var cond_stack: [64]bool = .{false} ** 64; // true = currently in else branch
    var else_depth: u32 = 0; // count of nesting levels currently in else branch

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
                        try processInclude(allocator, defines, inc_path, v, include_dir, file_mtimes);
                    }
                }
            }
            continue;
        }

        // Handle #ifdef (but not #ifndef, matched separately below)
        if (std.mem.startsWith(u8, trimmed, "#ifdef")) {
            if (cond_depth < 64) {
                cond_stack[cond_depth] = false; // first branch
                cond_depth += 1;
            }
            comment_lines.clearRetainingCapacity();
            continue;
        }

        // Handle #if (but not #ifdef/#ifndef)
        if ((std.mem.startsWith(u8, trimmed, "#if ") or std.mem.startsWith(u8, trimmed, "#if\t")) and
            !std.mem.startsWith(u8, trimmed, "#ifdef") and !std.mem.startsWith(u8, trimmed, "#ifndef"))
        {
            if (cond_depth < 64) {
                cond_stack[cond_depth] = false; // first branch
                cond_depth += 1;
            }
            comment_lines.clearRetainingCapacity();
            continue;
        }

        // Track #ifndef for include guard detection + conditional tracking
        if (std.mem.startsWith(u8, trimmed, "#ifndef")) {
            const rest_ifndef = std.mem.trimLeft(u8, trimmed[7..], " \t");
            var ifndef_end: usize = 0;
            while (ifndef_end < rest_ifndef.len and helpers.isIdentChar(rest_ifndef[ifndef_end])) {
                ifndef_end += 1;
            }
            if (ifndef_end > 0) {
                last_ifndef = rest_ifndef[0..ifndef_end];
            }
            if (cond_depth < 64) {
                cond_stack[cond_depth] = false; // first branch
                cond_depth += 1;
            }
            continue;
        }

        // Handle #else / #elif — flip to else branch
        if (std.mem.startsWith(u8, trimmed, "#else") or std.mem.startsWith(u8, trimmed, "#elif")) {
            if (cond_depth > 0) {
                const top = cond_depth - 1;
                if (!cond_stack[top]) {
                    // Transitioning from first branch to else branch
                    cond_stack[top] = true;
                    else_depth += 1;
                }
            }
            comment_lines.clearRetainingCapacity();
            continue;
        }

        // Handle #endif — pop conditional stack
        if (std.mem.startsWith(u8, trimmed, "#endif")) {
            if (cond_depth > 0) {
                cond_depth -= 1;
                if (cond_stack[cond_depth]) {
                    // Was in else branch — decrement else_depth
                    else_depth -= 1;
                    cond_stack[cond_depth] = false;
                }
            }
            comment_lines.clearRetainingCapacity();
            continue;
        }

        // Handle #define
        if (std.mem.startsWith(u8, trimmed, "#define")) {
            // Skip defines inside #else/#elif branches
            if (else_depth > 0) {
                // Consume continuation lines so we don't misparse them
                var skip_line = trimmed;
                while (skip_line.len > 0 and skip_line[skip_line.len - 1] == '\\') {
                    if (line_iter.next()) |cont_raw| {
                        line_num += 1;
                        skip_line = std.mem.trimRight(u8, cont_raw, "\r");
                    } else break;
                }
                comment_lines.clearRetainingCapacity();
                continue;
            }

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

            // Skip include guards: empty body + (matches preceding #ifndef OR name ends with _H)
            if (body.len == 0) {
                const is_guard = if (last_ifndef) |ifndef_name|
                    std.ascii.eqlIgnoreCase(name, ifndef_name)
                else
                    false;
                if (is_guard or std.mem.endsWith(u8, name, "_H")) {
                    last_ifndef = null;
                    comment_lines.clearRetainingCapacity();
                    continue;
                }
            }
            last_ifndef = null;

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

/// Get the mtime of a file, or null if the file cannot be stat'd.
fn getFileMtime(path: []const u8) ?i128 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    return stat.mtime;
}

/// Check if all previously recorded file mtimes are still valid.
fn mtimesStillValid(mtimes: []const FileMtime) bool {
    for (mtimes) |entry| {
        const current = getFileMtime(entry.path) orelse return false;
        if (current != entry.mtime) return false;
    }
    return true;
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
    file_mtimes: ?*std.ArrayListUnmanaged(FileMtime),
) ParseError!void {
    // Resolve include path (handles backslashes and case-insensitive matching)
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const full_path = helpers.resolveIncludePath(&path_buf, include_dir, inc_path) orelse {
        log.debug("could not resolve include path '{s}' in '{s}'", .{ inc_path, include_dir });
        return;
    };

    // Check visited
    if (visited.get(full_path) != null) return;
    const path_dupe = try allocator.dupe(u8, full_path);
    try visited.put(allocator, path_dupe, {});

    // Read the file using page_allocator so content can be freed after parsing
    // (all extracted data is duped into the arena before this function returns)
    const content = std.fs.cwd().readFileAlloc(std.heap.page_allocator, full_path, 1024 * 1024) catch |err| {
        log.debug("failed to read include '{s}': {}", .{ full_path, err });
        return;
    };
    defer std.heap.page_allocator.free(content);

    // Record the file's mtime for cache invalidation
    if (file_mtimes) |mtimes| {
        if (getFileMtime(full_path)) |mtime| {
            try mtimes.append(allocator, .{ .path = path_dupe, .mtime = mtime });
        }
    }

    // Use the included file's directory for resolving its own nested includes
    const nested_include_dir = std.fs.path.dirname(full_path) orelse include_dir;
    const nested_dir_dupe = try allocator.dupe(u8, nested_include_dir);

    try parseDefinesFromText(allocator, defines, content, path_dupe, visited, nested_dir_dupe, file_mtimes);
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
        const limit = @min(def.body.len, 80);
        for (def.body[0..limit]) |ch| {
            try w.writeByte(if (ch == '\n') ' ' else ch);
        }
        if (def.body.len > 80) {
            try w.writeAll("...");
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

test "skip include guard with non-_H suffix (H_DIK pattern)" {
    const allocator = std.testing.allocator;
    const text = "#ifndef H_DIK\n#define H_DIK\n#define DIK_ESCAPE 1\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    try std.testing.expect(defs.lookup("H_DIK") == null);
    try std.testing.expect(defs.lookup("DIK_ESCAPE") != null);
}

test "skip include guard with _H suffix even without #ifndef" {
    const allocator = std.testing.allocator;
    // _H suffix fallback still works without a preceding #ifndef
    const text = "#define DEFINE_LITE_H\n#define FOO 1\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    try std.testing.expect(defs.lookup("DEFINE_LITE_H") == null);
    try std.testing.expect(defs.lookup("FOO") != null);
}

test "empty-body define without #ifndef is preserved when no _H suffix" {
    const allocator = std.testing.allocator;
    const text = "#define EMPTY_FLAG\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    // No #ifndef and no _H suffix — should be preserved
    try std.testing.expect(defs.lookup("EMPTY_FLAG") != null);
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

test "parse defines from dik.h skips H_DIK guard" {
    const allocator = std.testing.allocator;
    const text = "#include \"headers/dik.h\"\n";
    var defs = try extractDefines(allocator, text, "test", null);
    defer defs.deinit();

    // Guard should be skipped
    try std.testing.expect(defs.lookup("H_DIK") == null);
    // Actual defines should be present
    try std.testing.expect(defs.lookup("DIK_ESCAPE") != null);
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

test "lookupCaseInsensitive exact match" {
    const allocator = std.testing.allocator;
    const text = "#define WORLDMAP (0x1)\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookupCaseInsensitive("WORLDMAP").?;
    try std.testing.expectEqualStrings("WORLDMAP", def.name);
}

test "lookupCaseInsensitive lowercase match" {
    const allocator = std.testing.allocator;
    const text = "#define WORLDMAP (0x1)\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookupCaseInsensitive("worldmap").?;
    try std.testing.expectEqualStrings("WORLDMAP", def.name);
}

test "lookupCaseInsensitive mixed case match" {
    const allocator = std.testing.allocator;
    const text = "#define WorldMap (0x1)\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookupCaseInsensitive("WORLDMAP").?;
    try std.testing.expectEqualStrings("WorldMap", def.name);
}

test "lookupCaseInsensitive non-existent" {
    const allocator = std.testing.allocator;
    const text = "#define FOO 1\n";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    try std.testing.expect(defs.lookupCaseInsensitive("BAR") == null);
}

test "cache invalidated when header file mtime changes" {
    const allocator = std.testing.allocator;
    const tmp_dir = "/tmp/ssl_mtime_test";
    std.fs.cwd().makePath(tmp_dir ++ "/headers") catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // Create initial header
    {
        const f = std.fs.cwd().createFile(tmp_dir ++ "/headers/test.h", .{}) catch return;
        defer f.close();
        var buf: [256]u8 = undefined;
        var w = f.writer(&buf);
        w.interface.writeAll("#define CACHED_VAL 1\n") catch return;
        w.interface.flush() catch return;
    }

    const text = "#include \"headers/test.h\"\n#define LOCAL 1\n";
    var defs1 = try extractDefines(allocator, text, tmp_dir, null);
    defer defs1.deinit();

    try std.testing.expect(defs1.lookup("CACHED_VAL") != null);
    try std.testing.expectEqualStrings("1", defs1.lookup("CACHED_VAL").?.body);
    try std.testing.expect(defs1.file_mtimes.items.len > 0);

    // Modify the header file (change content)
    // Sleep briefly to ensure mtime changes (filesystem granularity)
    std.posix.nanosleep(0, 10_000_000); // 10ms
    {
        const f = std.fs.cwd().createFile(tmp_dir ++ "/headers/test.h", .{}) catch return;
        defer f.close();
        var buf: [256]u8 = undefined;
        var w = f.writer(&buf);
        w.interface.writeAll("#define CACHED_VAL 2\n") catch return;
        w.interface.flush() catch return;
    }

    // Same includes text, but header mtime changed — cache should be invalidated
    var defs2 = try extractDefines(allocator, text, tmp_dir, &defs1);
    defer defs2.deinit();

    // Should have re-read from disk and found the new value
    try std.testing.expect(defs2.lookup("CACHED_VAL") != null);
    try std.testing.expectEqualStrings("2", defs2.lookup("CACHED_VAL").?.body);
}

test "ifdef/else keeps first branch defines" {
    const allocator = std.testing.allocator;
    const text =
        \\#ifdef SOMETHING
        \\#define VALUE 1
        \\#else
        \\#define VALUE 2
        \\#endif
        \\
    ;
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("VALUE").?;
    try std.testing.expectEqualStrings("1", def.body);
}

test "nested ifdef blocks" {
    const allocator = std.testing.allocator;
    const text =
        \\#define OUTER 1
        \\#ifdef FOO
        \\#define INNER_IF 10
        \\#ifdef BAR
        \\#define NESTED_IF 20
        \\#else
        \\#define NESTED_ELSE 30
        \\#endif
        \\#else
        \\#define OUTER_ELSE 40
        \\#endif
        \\#define AFTER 99
        \\
    ;
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    // Defines outside conditionals are kept
    try std.testing.expectEqualStrings("1", defs.lookup("OUTER").?.body);
    try std.testing.expectEqualStrings("99", defs.lookup("AFTER").?.body);

    // First branches are kept
    try std.testing.expect(defs.lookup("INNER_IF") != null);
    try std.testing.expect(defs.lookup("NESTED_IF") != null);

    // Else branches are skipped
    try std.testing.expect(defs.lookup("NESTED_ELSE") == null);
    try std.testing.expect(defs.lookup("OUTER_ELSE") == null);
}

test "define on last line without trailing newline" {
    const allocator = std.testing.allocator;
    const text = "#define LAST_LINE 42";
    var defs = try extractDefines(allocator, text, ".", null);
    defer defs.deinit();

    const def = defs.lookup("LAST_LINE").?;
    try std.testing.expectEqualStrings("42", def.body);
}

test "formatDetail truncates long body" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Create a define with a body > 80 chars
    const long_body = "a" ** 100;
    const def = Define{
        .name = "LONG",
        .params = null,
        .body = long_body,
        .file = "",
        .line = 1,
        .doc_comment = null,
    };
    const detail = try formatDetail(arena.allocator(), def);
    // Should be "#define LONG " + 80 chars + "..."
    try std.testing.expect(std.mem.endsWith(u8, detail, "..."));
    try std.testing.expect(detail.len == "#define LONG ".len + 80 + 3);
}
