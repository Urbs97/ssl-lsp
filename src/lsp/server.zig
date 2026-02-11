const std = @import("std");
const transport = @import("transport.zig");
const types = @import("types.zig");
const errors = @import("../parsing/errors.zig");
const parser = @import("../parsing/parser.zig");

const log = std.log.scoped(.server);

/// Stored document with content and cached parse result
const Document = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    parse_result: ?parser.ParseResult = null,

    fn deinit(self: *Document) void {
        self.allocator.free(self.text);
        if (self.parse_result) |*pr| pr.deinit();
    }
};

/// Stored documents keyed by URI
const DocumentMap = std.StringHashMapUnmanaged(Document);

/// Main LSP server state
const Server = struct {
    allocator: std.mem.Allocator,
    documents: DocumentMap,
    stdout_writer: std.fs.File.Writer,
    initialized: bool,
    shutdown_requested: bool,

    fn init(allocator: std.mem.Allocator, stdout_buf: []u8) Server {
        return .{
            .allocator = allocator,
            .documents = .empty,
            .stdout_writer = std.fs.File.stdout().writer(stdout_buf),
            .initialized = false,
            .shutdown_requested = false,
        };
    }

    fn deinit(self: *Server) void {
        var it = self.documents.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.documents.deinit(self.allocator);
    }

    /// Send a JSON object as a JSON-RPC message, serialized and framed.
    fn sendJson(self: *Server, obj: std.json.Value) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        try std.json.Stringify.value(obj, .{}, &out.writer);

        const stdout = &self.stdout_writer.interface;
        try transport.writeMessage(stdout, out.written());
        try stdout.flush();
    }

    /// Send a JSON-RPC response
    fn sendResponse(self: *Server, allocator: std.mem.Allocator, id: std.json.Value, result: std.json.Value) !void {
        var response = std.json.ObjectMap.init(allocator);
        try response.put("jsonrpc", .{ .string = "2.0" });
        try response.put("id", id);
        try response.put("result", result);
        try self.sendJson(.{ .object = response });
    }

    /// Send a JSON-RPC notification (no id)
    fn sendNotification(self: *Server, allocator: std.mem.Allocator, method: []const u8, params: std.json.Value) !void {
        var notification = std.json.ObjectMap.init(allocator);
        try notification.put("jsonrpc", .{ .string = "2.0" });
        try notification.put("method", .{ .string = method });
        try notification.put("params", params);
        try self.sendJson(.{ .object = notification });
    }

    /// Send an error response
    fn sendError(self: *Server, allocator: std.mem.Allocator, id: std.json.Value, code: i64, message: []const u8) !void {
        var err_obj = std.json.ObjectMap.init(allocator);
        try err_obj.put("code", .{ .integer = code });
        try err_obj.put("message", .{ .string = message });

        var response = std.json.ObjectMap.init(allocator);
        try response.put("jsonrpc", .{ .string = "2.0" });
        try response.put("id", id);
        try response.put("error", .{ .object = err_obj });
        try self.sendJson(.{ .object = response });
    }

    /// Handle a parsed JSON-RPC message
    fn handleMessage(self: *Server, json: std.json.Value) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        const obj = switch (json) {
            .object => |o| o,
            else => {
                log.err("expected JSON object, got {s}", .{@tagName(json)});
                return;
            },
        };

        const method_val = obj.get("method") orelse {
            log.err("missing 'method' field in JSON-RPC message", .{});
            return;
        };
        const method = switch (method_val) {
            .string => |s| s,
            else => {
                log.err("expected string for 'method', got {s}", .{@tagName(method_val)});
                return;
            },
        };

        const id = obj.get("id");
        const params = obj.get("params") orelse .null;

        if (std.mem.eql(u8, method, "initialize")) {
            try self.handleInitialize(allocator, id orelse .null);
        } else if (std.mem.eql(u8, method, "initialized")) {
            self.initialized = true;
            log.info("client initialized", .{});
        } else if (std.mem.eql(u8, method, "shutdown")) {
            self.shutdown_requested = true;
            try self.sendResponse(allocator, id orelse .null, .null);
            log.info("shutdown requested", .{});
        } else if (std.mem.eql(u8, method, "exit")) {
            const exit_code: u8 = if (self.shutdown_requested) 0 else 1;
            std.process.exit(exit_code);
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(allocator, params);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(allocator, params);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(allocator, params);
        } else if (std.mem.eql(u8, method, "textDocument/documentSymbol")) {
            if (id) |req_id| {
                try self.handleDocumentSymbol(allocator, req_id, params);
            }
        } else {
            // Unknown method - send MethodNotFound for requests (those with id)
            if (id) |req_id| {
                try self.sendError(allocator, req_id, -32601, "method not found");
            }
        }
    }

    fn handleInitialize(self: *Server, allocator: std.mem.Allocator, id: std.json.Value) !void {
        var capabilities = std.json.ObjectMap.init(allocator);
        try capabilities.put("textDocumentSync", .{ .integer = 1 });
        try capabilities.put("documentSymbolProvider", .{ .bool = true });

        var result = std.json.ObjectMap.init(allocator);
        try result.put("capabilities", .{ .object = capabilities });

        var server_info = std.json.ObjectMap.init(allocator);
        try server_info.put("name", .{ .string = "ssl-lsp" });
        try server_info.put("version", .{ .string = "0.1.0" });
        try result.put("serverInfo", .{ .object = server_info });

        try self.sendResponse(allocator, id, .{ .object = result });
        log.info("initialized", .{});
    }

    fn handleDidOpen(self: *Server, allocator: std.mem.Allocator, params: std.json.Value) !void {
        const td = getObject(params, "textDocument") orelse {
            log.err("didOpen: missing 'textDocument'", .{});
            return;
        };
        const uri = getString(td, "uri") orelse {
            log.err("didOpen: missing 'uri'", .{});
            return;
        };
        const text = getString(td, "text") orelse {
            log.err("didOpen: missing 'text'", .{});
            return;
        };

        const uri_dupe = try self.allocator.dupe(u8, uri);
        const text_dupe = try self.allocator.dupe(u8, text);

        const result = try self.documents.getOrPut(self.allocator, uri_dupe);
        if (result.found_existing) {
            self.allocator.free(result.key_ptr.*);
            result.value_ptr.deinit();
            result.key_ptr.* = uri_dupe;
        }
        result.value_ptr.* = .{ .allocator = self.allocator, .text = text_dupe };

        log.info("opened: {s}", .{uri});
        try self.publishDiagnostics(allocator, uri, text);
    }

    fn handleDidChange(self: *Server, allocator: std.mem.Allocator, params: std.json.Value) !void {
        const td = getObject(params, "textDocument") orelse {
            log.err("didChange: missing 'textDocument'", .{});
            return;
        };
        const uri = getString(td, "uri") orelse {
            log.err("didChange: missing 'uri'", .{});
            return;
        };

        // Full sync mode: contentChanges[0].text has the full content
        const changes = getArray(params, "contentChanges") orelse {
            log.err("didChange: missing 'contentChanges'", .{});
            return;
        };
        if (changes.len == 0) return;
        const text = getString(changes[0], "text") orelse return;

        if (self.documents.getPtr(uri)) |doc| {
            doc.allocator.free(doc.text);
            if (doc.parse_result) |*pr| pr.deinit();
            doc.text = try doc.allocator.dupe(u8, text);
            doc.parse_result = null;
        }

        try self.publishDiagnostics(allocator, uri, text);
    }

    fn handleDidClose(self: *Server, allocator: std.mem.Allocator, params: std.json.Value) !void {
        const td = getObject(params, "textDocument") orelse {
            log.err("didClose: missing 'textDocument'", .{});
            return;
        };
        const uri = getString(td, "uri") orelse {
            log.err("didClose: missing 'uri'", .{});
            return;
        };

        if (self.documents.fetchRemove(uri)) |entry| {
            self.allocator.free(entry.key);
            var doc = entry.value;
            doc.deinit();
        }

        // Clear diagnostics for closed file
        try self.publishDiagnostics(allocator, uri, "");
        log.info("closed: {s}", .{uri});
    }

    // HACK: adjust the parser C library to accept source content in-memory
    // instead of requiring a file path, to avoid this temp file workaround.

    /// Write document to temp file, run parser, convert errors to LSP diagnostics
    fn publishDiagnostics(self: *Server, allocator: std.mem.Allocator, uri: []const u8, text: []const u8) !void {
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

        // Cache the parse result in the document
        if (self.documents.getPtr(uri)) |doc| {
            if (doc.parse_result) |*old| old.deinit();
            doc.parse_result = parse_result;
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

                const diag_json = try types.diagnosticToJson(allocator, diag);
                try diag_array.append(diag_json);
            }
        }

        // Build and send publishDiagnostics notification
        var params_obj = std.json.ObjectMap.init(allocator);
        try params_obj.put("uri", .{ .string = uri });
        try params_obj.put("diagnostics", .{ .array = diag_array });

        try self.sendNotification(allocator, "textDocument/publishDiagnostics", .{ .object = params_obj });
    }

    fn handleDocumentSymbol(self: *Server, allocator: std.mem.Allocator, id: std.json.Value, params: std.json.Value) !void {
        const td = getObject(params, "textDocument") orelse {
            log.err("documentSymbol: missing 'textDocument'", .{});
            try self.sendResponse(allocator, id, .{ .array = std.json.Array.init(allocator) });
            return;
        };
        const uri = getString(td, "uri") orelse {
            log.err("documentSymbol: missing 'uri'", .{});
            try self.sendResponse(allocator, id, .{ .array = std.json.Array.init(allocator) });
            return;
        };

        const doc = self.documents.getPtr(uri) orelse {
            log.debug("documentSymbol: unknown document {s}", .{uri});
            try self.sendResponse(allocator, id, .{ .array = std.json.Array.init(allocator) });
            return;
        };

        var pr = doc.parse_result orelse {
            try self.sendResponse(allocator, id, .{ .array = std.json.Array.init(allocator) });
            return;
        };

        var symbols = std.json.Array.init(allocator);

        // Build procedure symbols
        for (0..pr.num_procs) |i| {
            const proc = pr.getProc(i);

            // Skip undefined (forward-declared only) procs
            if (!proc.defined) continue;

            const start_line = if (proc.start_line) |l| if (l > 0) l - 1 else 0 else 0;
            const end_line = if (proc.end_line) |l| if (l > 0) l - 1 else 0 else start_line;

            const range = types.Range{
                .start = .{ .line = start_line, .character = 0 },
                .end = .{ .line = end_line, .character = 0 },
            };

            // declared_line for selection range (the "procedure" keyword line)
            const decl_line: u32 = if (proc.declared_line > 0) proc.declared_line - 1 else 0;
            const selection_range = types.Range{
                .start = .{ .line = decl_line, .character = 0 },
                .end = .{ .line = decl_line, .character = 0 },
            };

            // Format flags as detail string
            var flags_buf: [128]u8 = undefined;
            const flags_str = proc.flags.format(&flags_buf);
            const detail: ?[]const u8 = if (!std.mem.eql(u8, flags_str, "(none)")) flags_str else null;

            // Build children: local variables of this procedure
            var children: ?[]const types.DocumentSymbol = null;
            if (proc.num_local_vars > 0) {
                var child_list = try std.ArrayListUnmanaged(types.DocumentSymbol).initCapacity(allocator, proc.num_local_vars);
                for (0..proc.num_local_vars) |vi| {
                    const local_var = pr.getProcVar(i, vi);
                    const var_line: u32 = if (local_var.declared_line > 0) local_var.declared_line - 1 else 0;
                    const var_range = types.Range{
                        .start = .{ .line = var_line, .character = 0 },
                        .end = .{ .line = var_line, .character = 0 },
                    };
                    child_list.appendAssumeCapacity(.{
                        .name = local_var.name,
                        .detail = local_var.var_type.name(),
                        .kind = .Variable,
                        .range = var_range,
                        .selection_range = var_range,
                    });
                }
                children = child_list.items;
            }

            const sym = types.DocumentSymbol{
                .name = proc.name,
                .detail = detail,
                .kind = .Function,
                .range = range,
                .selection_range = selection_range,
                .children = children,
            };
            try symbols.append(try types.documentSymbolToJson(allocator, sym));
        }

        // Build global variable symbols
        for (0..pr.num_vars) |i| {
            const v = pr.getVar(i);
            const var_line: u32 = if (v.declared_line > 0) v.declared_line - 1 else 0;
            const var_range = types.Range{
                .start = .{ .line = var_line, .character = 0 },
                .end = .{ .line = var_line, .character = 0 },
            };

            const sym = types.DocumentSymbol{
                .name = v.name,
                .detail = v.var_type.name(),
                .kind = .Variable,
                .range = var_range,
                .selection_range = var_range,
            };
            try symbols.append(try types.documentSymbolToJson(allocator, sym));
        }

        try self.sendResponse(allocator, id, .{ .array = symbols });
    }
};

// JSON helper functions

fn getObject(val: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (val) {
        .object => |obj| if (obj.get(key)) |v| v else null,
        else => null,
    };
}

fn getString(val: std.json.Value, key: []const u8) ?[]const u8 {
    const v = switch (val) {
        .object => |obj| obj.get(key) orelse return null,
        else => return null,
    };
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn getArray(val: std.json.Value, key: []const u8) ?[]std.json.Value {
    const v = switch (val) {
        .object => |obj| obj.get(key) orelse return null,
        else => return null,
    };
    return switch (v) {
        .array => |a| a.items,
        else => null,
    };
}

/// Entry point for LSP mode
pub fn run(allocator: std.mem.Allocator) !void {
    log.info("ssl-lsp server starting", .{});

    var stdout_buf: [4096]u8 = undefined;
    var server = Server.init(allocator, &stdout_buf);
    defer server.deinit();

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const reader = &stdin_reader.interface;

    while (true) {
        const body = transport.readMessage(allocator, reader) catch |err| {
            if (err == error.EndOfStream) {
                log.info("stdin closed, exiting", .{});
                return;
            }
            log.err("failed to read message: {}", .{err});
            continue;
        };
        defer allocator.free(body);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch |err| {
            log.err("failed to parse JSON: {}", .{err});
            continue;
        };
        defer parsed.deinit();

        server.handleMessage(parsed.value) catch |err| {
            log.err("failed to handle message: {}", .{err});
        };
    }
}
