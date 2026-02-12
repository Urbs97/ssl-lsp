const std = @import("std");
const transport = @import("transport.zig");
const types = @import("types.zig");
const errors = @import("../parsing/errors.zig");
const parser = @import("../parsing/parser.zig");
const defines_mod = @import("defines.zig");

const log = std.log.scoped(.server);

/// Stored document with content and cached parse result
pub const Document = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    parse_result: ?parser.ParseResult = null,
    defines: ?defines_mod.DefineSet = null,

    pub fn deinit(self: *Document) void {
        self.allocator.free(self.text);
        if (self.parse_result) |*pr| pr.deinit();
        if (self.defines) |*d| d.deinit();
    }
};

/// Stored documents keyed by URI
pub const DocumentMap = std.StringHashMapUnmanaged(Document);

/// Main LSP server state
pub const Context = struct {
    allocator: std.mem.Allocator,
    documents: DocumentMap,
    stdout_writer: std.fs.File.Writer,
    initialized: bool,
    shutdown_requested: bool,

    pub fn init(allocator: std.mem.Allocator, stdout_buf: []u8) Context {
        return .{
            .allocator = allocator,
            .documents = .empty,
            .stdout_writer = std.fs.File.stdout().writer(stdout_buf),
            .initialized = false,
            .shutdown_requested = false,
        };
    }

    pub fn deinit(self: *Context) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.documents.deinit(self.allocator);
    }

    /// Send a JSON object as a JSON-RPC message, serialized and framed.
    pub fn sendJson(self: *Context, obj: std.json.Value) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        try std.json.Stringify.value(obj, .{}, &out.writer);

        const stdout = &self.stdout_writer.interface;
        try transport.writeMessage(stdout, out.written());
        try stdout.flush();
    }

    /// Send a JSON-RPC response
    pub fn sendResponse(self: *Context, allocator: std.mem.Allocator, id: std.json.Value, result: std.json.Value) !void {
        var response = std.json.ObjectMap.init(allocator);
        try response.put("jsonrpc", .{ .string = "2.0" });
        try response.put("id", id);
        try response.put("result", result);
        try self.sendJson(.{ .object = response });
    }

    /// Send a JSON-RPC notification (no id)
    pub fn sendNotification(self: *Context, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) !void {
        var notification = std.json.ObjectMap.init(allocator);
        try notification.put("jsonrpc", .{ .string = "2.0" });
        try notification.put("method", .{ .string = method });
        try notification.put("params", params);
        try self.sendJson(.{ .object = notification });
    }

    /// Send an error response
    pub fn sendError(self: *Context, allocator: std.mem.Allocator, id: std.json.Value, code: i64, message: []const u8) !void {
        var err_obj = std.json.ObjectMap.init(allocator);
        try err_obj.put("code", .{ .integer = code });
        try err_obj.put("message", .{ .string = message });

        var response = std.json.ObjectMap.init(allocator);
        try response.put("jsonrpc", .{ .string = "2.0" });
        try response.put("id", id);
        try response.put("error", .{ .object = err_obj });
        try self.sendJson(.{ .object = response });
    }

    // HACK: adjust the parser C library to accept source content in-memory
    // instead of requiring a file path, to avoid this temp file workaround.

    /// Write document to temp file, run parser, convert errors to LSP diagnostics
    pub fn publishDiagnostics(self: *Context, allocator: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
        // TODO: std.posix is Linux-only, windows support is planned
        const tmp_dir = std.posix.getenv("TMPDIR") orelse std.posix.getenv("TMP") orelse std.posix.getenv("TEMP") orelse "/tmp";
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&path_buf, "{s}{c}{s}", .{ tmp_dir, std.fs.path.sep, "ssl-lsp-temp.ssl" });
        {
            const file = try std.fs.createFileAbsolute(tmp_path, .{});
            defer file.close();
            var buf: [4096]u8 = undefined;
            var w = file.writer(&buf);
            try w.interface.writeAll(text);
            try w.interface.flush();
        }

        // Resolve the original file's directory for include file resolution
        const file_path = if (std.mem.startsWith(u8, uri, "file://")) uri[7..] else uri;
        const include_dir = std.fs.path.dirname(file_path) orelse ".";

        // Run the parser using self.allocator so ParseResult outlives the arena
        var parse_result = parser.parse(self.allocator, tmp_path, tmp_path, include_dir) catch |err| blk: {
            log.debug("parser failed: {}", .{err});
            break :blk null;
        };

        // Cache the parse result in the document (keep old result on failure)
        if (self.documents.getPtr(uri)) |doc| {
            if (parse_result) |_| {
                if (doc.parse_result) |*old| old.deinit();
                doc.parse_result = parse_result;
            }

            // Extract #define macros from included headers
            if (doc.defines) |*old_defs| old_defs.deinit();
            doc.defines = defines_mod.extractDefines(self.allocator, text, include_dir) catch null;
        } else {
            // Document not in map (e.g. didClose clearing diagnostics) — clean up
            if (parse_result) |*pr| pr.deinit();
        }

        const error_list = try errors.readErrors(allocator);
        defer error_list.deinit();

        var diag_array = std.json.Array.init(allocator);

        if (parse_result == null or error_list.errors.len > 0) {
            for (error_list.errors) |err| {
                const severity: types.DiagnosticSeverity = switch (err.error_type) {
                    .@"error" => .Error,
                    .warning => .Warning,
                    .message => .Information,
                    .unknown => .Hint,
                };

                // Convert 1-indexed parser lines to 0-indexed LSP lines
                const line: u32 = if (err.line > 0) @intCast(err.line - 1) else 0;
                const col: u32 = if (err.column) |col_val| if (col_val > 0) @intCast(col_val - 1) else 0 else 0;

                const diag = types.Diagnostic{
                    .range = .{
                        .start = .{ .line = line, .character = col },
                        .end = .{ .line = line, .character = col },
                    },
                    .severity = severity,
                    .message = err.message,
                };

                const diag_json = try diag.toJson(allocator);
                try diag_array.append(diag_json);
            }
        }

        // Build and send publishDiagnostics notification
        var params_obj = std.json.ObjectMap.init(allocator);
        try params_obj.put("uri", .{ .string = uri });
        try params_obj.put("diagnostics", .{ .array = diag_array });

        try self.sendNotification(allocator, "textDocument/publishDiagnostics", .{ .object = params_obj });
    }
};
