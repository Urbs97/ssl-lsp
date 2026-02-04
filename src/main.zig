const std = @import("std");
const c = @cImport({
    @cInclude("parser.h");
});

/// Error types from the parser
const ErrorType = enum {
    @"error",
    warning,
    message,
    unknown,
};

/// Parsed error from errors.txt
const ParseError = struct {
    error_type: ErrorType,
    file_name: []const u8,
    line: i32,
    column: ?i32,
    message: []const u8,
};

/// Parse error type from string (case-insensitive)
fn parseErrorType(type_str: []const u8) ErrorType {
    if (std.ascii.eqlIgnoreCase(type_str, "error")) return .@"error";
    if (std.ascii.eqlIgnoreCase(type_str, "warning")) return .warning;
    if (std.ascii.eqlIgnoreCase(type_str, "message")) return .message;
    return .unknown;
}

/// Parse a single error line matching: [Type] <Category>? <file>:line:col?: message
/// Format: [\w+]\s*(\<\w+\>\s*)?\<([^\>]+)\>\s*\:(\-?\d+):?(\-?\d+)?\:\s*(.*)
fn parseErrorLine(line: []const u8) ?ParseError {
    var pos: usize = 0;

    // Skip leading whitespace
    while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;

    // Expect '['
    if (pos >= line.len or line[pos] != '[') return null;
    pos += 1;

    // Parse error type until ']'
    const type_start = pos;
    while (pos < line.len and line[pos] != ']') pos += 1;
    if (pos >= line.len) return null;
    const type_str = line[type_start..pos];
    pos += 1; // skip ']'

    // Skip whitespace
    while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;

    // Expect '<'
    if (pos >= line.len or line[pos] != '<') return null;
    pos += 1;

    // Parse first angle-bracketed content (could be category or file)
    const first_start = pos;
    while (pos < line.len and line[pos] != '>') pos += 1;
    if (pos >= line.len) return null;
    const first_content = line[first_start..pos];
    pos += 1; // skip '>'

    // Skip whitespace
    while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;

    // Check if there's another '<' (meaning first was category, second is file)
    var file_name: []const u8 = undefined;
    if (pos < line.len and line[pos] == '<') {
        // First content was category, now parse actual file name
        pos += 1;
        const file_start = pos;
        while (pos < line.len and line[pos] != '>') pos += 1;
        if (pos >= line.len) return null;
        file_name = line[file_start..pos];
        pos += 1; // skip '>'

        // Skip whitespace
        while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;
    } else {
        // First content was the file name
        file_name = first_content;
    }

    // Expect ':'
    if (pos >= line.len or line[pos] != ':') return null;
    pos += 1;

    // Parse line number (may be negative)
    const line_num = parseInteger(line, &pos) orelse return null;

    // Check for optional column number
    var col_num: ?i32 = null;
    if (pos < line.len and line[pos] == ':') {
        pos += 1;
        // Try to parse column - might be another colon if no column
        if (pos < line.len and (line[pos] == '-' or std.ascii.isDigit(line[pos]))) {
            col_num = parseInteger(line, &pos);
        }
    }

    // Expect ':' before message
    if (pos < line.len and line[pos] == ':') {
        pos += 1;
    }

    // Skip whitespace before message
    while (pos < line.len and std.ascii.isWhitespace(line[pos])) pos += 1;

    // Rest is the message
    const message = if (pos < line.len) line[pos..] else "";

    return ParseError{
        .error_type = parseErrorType(type_str),
        .file_name = file_name,
        .line = line_num,
        .column = col_num,
        .message = message,
    };
}

/// Parse an integer from the line at the given position
fn parseInteger(line: []const u8, pos: *usize) ?i32 {
    if (pos.* >= line.len) return null;

    var negative = false;
    if (line[pos.*] == '-') {
        negative = true;
        pos.* += 1;
    }

    if (pos.* >= line.len or !std.ascii.isDigit(line[pos.*])) return null;

    var value: i32 = 0;
    while (pos.* < line.len and std.ascii.isDigit(line[pos.*])) {
        value = value * 10 + @as(i32, @intCast(line[pos.*] - '0'));
        pos.* += 1;
    }

    return if (negative) -value else value;
}

/// Read and parse errors.txt file
fn readErrors(allocator: std.mem.Allocator) ![]ParseError {
    const file = std.fs.cwd().openFile("errors.txt", .{}) catch |err| {
        if (err == error.FileNotFound) return &.{};
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var errors: std.ArrayListUnmanaged(ParseError) = .empty;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (parseErrorLine(line)) |parsed| {
            // Duplicate strings since content will be freed
            const file_name = try allocator.dupe(u8, parsed.file_name);
            const message = try allocator.dupe(u8, parsed.message);
            try errors.append(allocator, .{
                .error_type = parsed.error_type,
                .file_name = file_name,
                .line = parsed.line,
                .column = parsed.column,
                .message = message,
            });
        }
    }

    return errors.toOwnedSlice(allocator);
}

/// Display parsed errors
fn displayErrors(errors: []const ParseError) void {
    if (errors.len == 0) return;

    std.debug.print("\nParser Messages: {d}\n", .{errors.len});
    std.debug.print("{s}\n", .{"-" ** 40});

    var error_count: usize = 0;
    var warning_count: usize = 0;
    var message_count: usize = 0;

    for (errors) |err| {
        const type_str: []const u8 = switch (err.error_type) {
            .@"error" => blk: {
                error_count += 1;
                break :blk "ERROR";
            },
            .warning => blk: {
                warning_count += 1;
                break :blk "WARN ";
            },
            .message => blk: {
                message_count += 1;
                break :blk "INFO ";
            },
            .unknown => "???? ",
        };

        if (err.column) |col| {
            std.debug.print("  [{s}] {s}:{d}:{d}: {s}\n", .{
                type_str,
                err.file_name,
                err.line,
                col,
                err.message,
            });
        } else {
            std.debug.print("  [{s}] {s}:{d}: {s}\n", .{
                type_str,
                err.file_name,
                err.line,
                err.message,
            });
        }
    }

    std.debug.print("\nSummary: {d} error(s), {d} warning(s), {d} message(s)\n", .{
        error_count,
        warning_count,
        message_count,
    });
}

/// Extract a name from the namespace buffer at the given offset.
/// The format is: 2 bytes length (big-endian at offset-6, offset-5), then string at offset-4
fn extractName(namespace: []const u8, name_offset: usize) ?[]const u8 {
    if (name_offset < 6 or name_offset > namespace.len) return null;

    const len_hi: u16 = namespace[name_offset - 5];
    const len_lo: u16 = namespace[name_offset - 6];
    const len = (len_hi << 8) | len_lo;

    const start = name_offset - 4;
    if (start + len > namespace.len) return null;

    // Trim trailing null
    var actual_len = len;
    while (actual_len > 0 and namespace[start + actual_len - 1] == 0) {
        actual_len -= 1;
    }

    return namespace[start..][0..actual_len];
}

/// Get variable type as string
fn varTypeStr(var_type: c_int) []const u8 {
    return switch (var_type) {
        c.V_LOCAL => "local",
        c.V_GLOBAL => "global",
        c.V_IMPORT => "import",
        c.V_EXPORT => "export",
        else => "unknown",
    };
}

/// Get procedure flags as string
fn procFlagsStr(flags: c_int, buf: []u8) []const u8 {
    var pos: usize = 0;

    if (flags & c.P_TIMED != 0) {
        const s = "timed ";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (flags & c.P_CONDITIONAL != 0) {
        const s = "conditional ";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (flags & c.P_IMPORT != 0) {
        const s = "import ";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (flags & c.P_EXPORT != 0) {
        const s = "export ";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (flags & c.P_CRITICAL != 0) {
        const s = "critical ";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (flags & c.P_PURE != 0) {
        const s = "pure ";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }
    if (flags & c.P_INLINE != 0) {
        const s = "inline ";
        @memcpy(buf[pos..][0..s.len], s);
        pos += s.len;
    }

    if (pos == 0) return "(none)";
    return buf[0 .. pos - 1]; // trim trailing space
}

pub fn main() !void {
    // Use debug allocator in debug builds for leak detection and safety checks
    const is_debug = comptime @import("builtin").mode == .Debug;
    var gpa = if (is_debug) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer if (is_debug) {
        _ = gpa.deinit();
    };
    const allocator = if (is_debug) gpa.allocator() else std.heap.page_allocator;

    // Get command line args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <script.ssl>\n", .{args[0]});
        return;
    }

    const script_path = args[1];
    std.debug.print("Parsing: {s}\n", .{script_path});
    std.debug.print("{s}\n", .{"=" ** 60});

    // Parse the script
    const result = c.parse_main(script_path.ptr, script_path.ptr, ".");

    // Read errors.txt (parser writes diagnostics here)
    const errors = try readErrors(allocator);
    defer {
        for (errors) |err| {
            allocator.free(err.file_name);
            allocator.free(err.message);
        }
        allocator.free(errors);
    }

    if (result != 0) {
        std.debug.print("Parse failed with code: {d}\n", .{result});
        // 0 = success, 1 = parse error, 2+ = preprocess error
        const result_desc: []const u8 = switch (result) {
            1 => " (parse error)",
            2 => " (preprocess error)",
            else => "",
        };
        std.debug.print("Exit code: {d}{s}\n", .{ result, result_desc });
        displayErrors(errors);
        return;
    }

    std.debug.print("Parse successful!\n", .{});

    // Display any warnings/messages even on success
    if (errors.len > 0) {
        displayErrors(errors);
    }
    std.debug.print("\n", .{});

    // Get namespace for name lookups
    const ns_size = c.namespaceSize();
    std.debug.print("Namespace size: {d} bytes\n", .{ns_size});

    var namespace: []u8 = &.{};
    defer if (namespace.len > 0) allocator.free(namespace);
    if (ns_size > 0) {
        namespace = try allocator.alloc(u8, @intCast(ns_size));
        c.getNamespace(namespace.ptr);
    }

    // Get string space
    const str_size = c.stringspaceSize();
    std.debug.print("String space size: {d} bytes\n\n", .{str_size});

    // List procedures
    const num_procs = c.numProcs();
    std.debug.print("Procedures: {d}\n", .{num_procs});
    std.debug.print("{s}\n", .{"-" ** 40});

    var i: c_int = 0;
    while (i < num_procs) : (i += 1) {
        var proc: c.Procedure = undefined;
        c.getProc(i, &proc);

        const name = if (namespace.len > 0)
            extractName(namespace, @intCast(proc.name)) orelse "<invalid>"
        else
            "<no namespace>";

        var flags_buf: [128]u8 = undefined;
        const flags = procFlagsStr(proc.type, &flags_buf);

        std.debug.print("  [{d}] {s}\n", .{ i, name });
        std.debug.print("      args: {d}, flags: {s}\n", .{ proc.numArgs, flags });
        std.debug.print("      declared: line {d}", .{proc.declared});
        if (proc.fdeclared) |f| {
            std.debug.print(" in {s}", .{f});
        }
        std.debug.print("\n", .{});

        if (proc.defined != 0) {
            std.debug.print("      defined: lines {d}-{d}", .{ proc.start, proc.end });
            if (proc.fstart) |f| {
                std.debug.print(" in {s}", .{f});
            }
            std.debug.print("\n", .{});
        }

        std.debug.print("      refs: {d}, local vars: {d}\n", .{ proc.numRefs, proc.variables.numVariables });

        // Show local variables
        if (proc.variables.numVariables > 0) {
            var j: c_int = 0;
            while (j < proc.variables.numVariables) : (j += 1) {
                var local_var: c.Variable = undefined;
                c.getProcVar(i, j, &local_var);

                // Local vars use procedure's namespace
                const proc_ns_size = c.getProcNamespaceSize(i);
                if (proc_ns_size > 0) {
                    const proc_ns = try allocator.alloc(u8, @intCast(proc_ns_size));
                    defer allocator.free(proc_ns);
                    c.getProcNamespace(i, proc_ns.ptr);

                    const var_name = extractName(proc_ns, @intCast(local_var.name)) orelse "<invalid>";
                    std.debug.print("        - {s} (line {d})\n", .{ var_name, local_var.declared });
                }
            }
        }

        std.debug.print("\n", .{});
    }

    // List global variables
    const num_vars = c.numVars();
    std.debug.print("Global Variables: {d}\n", .{num_vars});
    std.debug.print("{s}\n", .{"-" ** 40});

    i = 0;
    while (i < num_vars) : (i += 1) {
        var variable: c.Variable = undefined;
        c.getVar(i, &variable);

        const name = if (namespace.len > 0)
            extractName(namespace, @intCast(variable.name)) orelse "<invalid>"
        else
            "<no namespace>";

        const var_type = varTypeStr(variable.type);

        std.debug.print("  [{d}] {s} ({s})\n", .{ i, name, var_type });
        std.debug.print("      declared: line {d}", .{variable.declared});
        if (variable.fdeclared) |f| {
            std.debug.print(" in {s}", .{f});
        }
        std.debug.print(", refs: {d}\n", .{variable.numRefs});
    }

    std.debug.print("\n{s}\n", .{"=" ** 60});
    std.debug.print("Done!\n", .{});
}

test "parse minimal script" {
    const result = c.parse_main(
        "test/minimal.ssl",
        "test/minimal.ssl",
        "test",
    );

    try std.testing.expectEqual(@as(c_int, 0), result);

    const num_procs = c.numProcs();
    try std.testing.expectEqual(@as(c_int, 1), num_procs); // 'start' procedure

    const num_vars = c.numVars();
    try std.testing.expectEqual(@as(c_int, 1), num_vars); // 'count' variable
}

test "parse standalone script" {
    const result = c.parse_main(
        "test/standalone.ssl",
        "test/standalone.ssl",
        "test",
    );

    try std.testing.expectEqual(@as(c_int, 0), result);

    const num_procs = c.numProcs();
    try std.testing.expectEqual(@as(c_int, 7), num_procs);

    const num_vars = c.numVars();
    try std.testing.expectEqual(@as(c_int, 4), num_vars);

    // Check namespace is populated
    const ns_size = c.namespaceSize();
    try std.testing.expect(ns_size > 0);

    // Verify procedure info
    var proc: c.Procedure = undefined;
    c.getProc(0, &proc);
    try std.testing.expectEqual(@as(c_int, 0), proc.numArgs); // helper_proc has no args
    try std.testing.expectEqual(@as(c_int, 1), proc.variables.numVariables); // 1 local var

    c.getProc(1, &proc);
    try std.testing.expectEqual(@as(c_int, 2), proc.numArgs); // calculate has 2 args

    c.getProc(2, &proc);
    try std.testing.expect((proc.type & c.P_PURE) != 0); // double_value is pure

    c.getProc(3, &proc);
    try std.testing.expect((proc.type & c.P_INLINE) != 0); // add_to_counter is inline
}

test "parser API functions exist" {
    // Just verify all API functions are linked correctly
    _ = c.parse_main;
    _ = c.numProcs;
    _ = c.getProc;
    _ = c.getProcNamespaceSize;
    _ = c.getProcNamespace;
    _ = c.numVars;
    _ = c.getVar;
    _ = c.getProcVar;
    _ = c.namespaceSize;
    _ = c.getNamespace;
    _ = c.stringspaceSize;
    _ = c.getStringspace;
    _ = c.getProcRefs;
    _ = c.getVarRefs;
    _ = c.getProcVarRefs;
}

test "parseErrorLine parses error with line only" {
    const line = "[Error] <test.ssl>:10: Undefined symbol 'foo'";
    const result = parseErrorLine(line);
    try std.testing.expect(result != null);
    const err = result.?;
    try std.testing.expectEqual(ErrorType.@"error", err.error_type);
    try std.testing.expectEqualStrings("test.ssl", err.file_name);
    try std.testing.expectEqual(@as(i32, 10), err.line);
    try std.testing.expectEqual(@as(?i32, null), err.column);
    try std.testing.expectEqualStrings("Undefined symbol 'foo'", err.message);
}

test "parseErrorLine parses error with line and column" {
    const line = "[Warning] <script.ssl>:25:8: Unused variable 'x'";
    const result = parseErrorLine(line);
    try std.testing.expect(result != null);
    const err = result.?;
    try std.testing.expectEqual(ErrorType.warning, err.error_type);
    try std.testing.expectEqualStrings("script.ssl", err.file_name);
    try std.testing.expectEqual(@as(i32, 25), err.line);
    try std.testing.expectEqual(@as(?i32, 8), err.column);
    try std.testing.expectEqualStrings("Unused variable 'x'", err.message);
}

test "parseErrorLine parses message type" {
    const line = "[Message] <info.ssl>:1: Some info message";
    const result = parseErrorLine(line);
    try std.testing.expect(result != null);
    const err = result.?;
    try std.testing.expectEqual(ErrorType.message, err.error_type);
}

test "parseErrorLine handles negative line number" {
    const line = "[Error] <file.ssl>:-1: No line info available";
    const result = parseErrorLine(line);
    try std.testing.expect(result != null);
    const err = result.?;
    try std.testing.expectEqual(@as(i32, -1), err.line);
}

test "parseErrorLine returns null for invalid format" {
    try std.testing.expect(parseErrorLine("not an error line") == null);
    try std.testing.expect(parseErrorLine("[Error] missing angle brackets") == null);
    try std.testing.expect(parseErrorLine("") == null);
}

test "parseErrorType is case insensitive" {
    try std.testing.expectEqual(ErrorType.@"error", parseErrorType("Error"));
    try std.testing.expectEqual(ErrorType.@"error", parseErrorType("ERROR"));
    try std.testing.expectEqual(ErrorType.@"error", parseErrorType("error"));
    try std.testing.expectEqual(ErrorType.warning, parseErrorType("Warning"));
    try std.testing.expectEqual(ErrorType.warning, parseErrorType("WARNING"));
    try std.testing.expectEqual(ErrorType.message, parseErrorType("Message"));
    try std.testing.expectEqual(ErrorType.unknown, parseErrorType("other"));
}
