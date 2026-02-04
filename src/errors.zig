const std = @import("std");

/// Error types from the parser
pub const ErrorType = enum {
    @"error",
    warning,
    message,
    unknown,
};

/// Parsed error from errors.txt
pub const ParseError = struct {
    error_type: ErrorType,
    file_name: []const u8,
    line: i32,
    column: ?i32,
    message: []const u8,
};

/// Parse error type from string (case-insensitive)
pub fn parseErrorType(type_str: []const u8) ErrorType {
    if (std.ascii.eqlIgnoreCase(type_str, "error")) return .@"error";
    if (std.ascii.eqlIgnoreCase(type_str, "warning")) return .warning;
    if (std.ascii.eqlIgnoreCase(type_str, "message")) return .message;
    return .unknown;
}

/// Parse a single error line matching: [Type] <Category>? <file>:line:col?: message
/// Format: [\w+]\s*(\<\w+\>\s*)?\<([^\>]+)\>\s*\:(\-?\d+):?(\-?\d+)?\:\s*(.*)
pub fn parseErrorLine(line: []const u8) ?ParseError {
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
pub fn readErrors(allocator: std.mem.Allocator) ![]ParseError {
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
pub fn displayErrors(errors: []const ParseError) void {
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

/// Free errors allocated by readErrors
pub fn freeErrors(allocator: std.mem.Allocator, errors: []ParseError) void {
    for (errors) |err| {
        allocator.free(err.file_name);
        allocator.free(err.message);
    }
    allocator.free(errors);
}

// Tests

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
