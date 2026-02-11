const std = @import("std");

const log = std.log.scoped(.transport);

/// Read a single JSON-RPC message from stdin.
/// Parses Content-Length header, then reads exactly that many bytes.
/// Returns owned slice that caller must free.
pub fn readMessage(allocator: std.mem.Allocator, reader: *std.io.Reader) ![]const u8 {
    // Parse headers - look for Content-Length
    var content_length: ?usize = null;

    while (true) {
        const header_line = reader.takeDelimiter('\n') catch |err| {
            log.err("failed to read header: {}", .{err});
            return error.InvalidHeader;
        } orelse return error.EndOfStream;

        // Trim trailing \r
        const trimmed = std.mem.trimRight(u8, header_line, "\r");

        // Empty line = end of headers
        if (trimmed.len == 0) break;

        // Parse Content-Length header
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const value_str = std.mem.trimLeft(u8, trimmed["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, value_str, 10) catch {
                log.err("invalid Content-Length value: '{s}'", .{value_str});
                return error.InvalidHeader;
            };
        }
        // Ignore other headers (Content-Type, etc.)
    }

    const len = content_length orelse {
        log.err("missing Content-Length header", .{});
        return error.InvalidHeader;
    };

    // Read the JSON body
    return try reader.readAlloc(allocator, len);
}

/// Write a JSON-RPC message to the writer with Content-Length header.
pub fn writeMessage(writer: *std.io.Writer, body: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
}
