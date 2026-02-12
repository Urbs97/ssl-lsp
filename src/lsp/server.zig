const std = @import("std");
const transport = @import("transport.zig");
const context = @import("context.zig");
const Context = context.Context;

const initialize = @import("methods/initialize.zig");
const initialized = @import("methods/initialized.zig");
const shutdown = @import("methods/shutdown.zig");
const exit = @import("methods/exit.zig");
const did_open = @import("methods/did_open.zig");
const did_change = @import("methods/did_change.zig");
const did_close = @import("methods/did_close.zig");
const document_symbol = @import("methods/document_symbol.zig");
const definition = @import("methods/definition.zig");
const references = @import("methods/references.zig");
const hover = @import("methods/hover.zig");
const completion = @import("methods/completion.zig");
const builtins = @import("builtins.zig");

const log = std.log.scoped(.server);

const Handler = *const fn (*Context, std.mem.Allocator, ?std.json.Value, std.json.Value) anyerror!void;

const Route = struct {
    method: []const u8,
    handler: Handler,
};

const routes = [_]Route{
    .{ .method = "initialize", .handler = initialize.handle },
    .{ .method = "initialized", .handler = initialized.handle },
    .{ .method = "shutdown", .handler = shutdown.handle },
    .{ .method = "exit", .handler = exit.handle },
    .{ .method = "textDocument/didOpen", .handler = did_open.handle },
    .{ .method = "textDocument/didChange", .handler = did_change.handle },
    .{ .method = "textDocument/didClose", .handler = did_close.handle },
    .{ .method = "textDocument/documentSymbol", .handler = document_symbol.handle },
    .{ .method = "textDocument/definition", .handler = definition.handle },
    .{ .method = "textDocument/references", .handler = references.handle },
    .{ .method = "textDocument/hover", .handler = hover.handle },
    .{ .method = "textDocument/completion", .handler = completion.handle },
};

fn handleMessage(ctx: *Context, json_val: std.json.Value) !void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const obj = switch (json_val) {
        .object => |o| o,
        else => {
            log.err("expected JSON object, got {s}", .{@tagName(json_val)});
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

    inline for (routes) |route| {
        if (std.mem.eql(u8, method, route.method)) {
            try route.handler(ctx, allocator, id, params);
            return;
        }
    }

    // Unknown method - send MethodNotFound for requests (those with id)
    if (id) |req_id| {
        try ctx.sendError(allocator, req_id, -32601, "method not found");
    }
}

/// Entry point for LSP mode
pub fn run(allocator: std.mem.Allocator) !void {
    log.info("ssl-lsp server starting", .{});

    try builtins.init(allocator);
    defer builtins.deinit(allocator);

    var stdout_buf: [4096]u8 = undefined;
    var ctx = Context.init(allocator, &stdout_buf);
    defer ctx.deinit();

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

        handleMessage(&ctx, parsed.value) catch |err| {
            log.err("failed to handle message: {}", .{err});
        };
    }
}

test {
    _ = context;
    _ = @import("helpers.zig");
    _ = initialize;
    _ = initialized;
    _ = shutdown;
    _ = exit;
    _ = did_open;
    _ = did_change;
    _ = did_close;
    _ = document_symbol;
    _ = definition;
    _ = references;
    _ = hover;
    _ = completion;
    _ = builtins;
}
