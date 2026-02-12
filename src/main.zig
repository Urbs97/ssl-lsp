const std = @import("std");
const parser = @import("parsing/parser.zig");
const errors = @import("parsing/errors.zig");
const lsp_server = @import("lsp/server.zig");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .server, .level = .info },
        .{ .scope = .transport, .level = .info },
    },
};

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
        printUsage(args[0]);
        return;
    }

    if (std.mem.eql(u8, args[1], "--stdio")) {
        return lsp_server.run(allocator);
    }

    if (std.mem.eql(u8, args[1], "--lint")) {
        if (args.len < 3) {
            std.log.err("--lint requires a script path", .{});
            printUsage(args[0]);
            std.process.exit(1);
        }
        return runLint(allocator, args[2]);
    }

    printUsage(args[0]);
}

fn printUsage(program_name: []const u8) void {
    std.debug.print(
        \\Usage:
        \\  {s} --lint <script.ssl>  Lint a script file
        \\  {s} --stdio              Start LSP server (stdio transport)
        \\
    , .{ program_name, program_name });
}

fn runLint(allocator: std.mem.Allocator, script_path: []const u8) !void {
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    stderr.print("Linting: {s}\n", .{script_path}) catch {};

    // Parse the script
    var result = parser.parse(allocator, script_path, script_path, ".") catch |err| {
        const error_list = try errors.readErrors(allocator);
        defer error_list.deinit();

        const desc: []const u8 = switch (err) {
            error.ParseFailed => "parse error",
            error.PreprocessFailed => "preprocess error",
            error.UnknownError => "unknown error",
            error.OutOfMemory => "out of memory",
        };
        stderr.print("Parse failed: {s}\n", .{desc}) catch {};
        error_list.displayErrors(stderr);
        stderr.flush() catch {};
        std.process.exit(1);
    };
    defer result.deinit();

    // Read errors.txt (parser writes diagnostics here)
    const error_list = try errors.readErrors(allocator);
    defer error_list.deinit();

    // Display any warnings/messages even on success
    if (error_list.errors.len > 0) {
        error_list.displayErrors(stderr);
    }

    const num_errors = error_list.countErrors();
    if (num_errors > 0) {
        stderr.print("Lint failed: {d} error(s) found.\n", .{num_errors}) catch {};
        stderr.flush() catch {};
        std.process.exit(1);
    }

    stderr.print("No errors found.\n", .{}) catch {};
    stderr.flush() catch {};
}

// Import tests from submodules
test {
    _ = @import("parsing/parser.zig");
    _ = @import("parsing/errors.zig");
    _ = @import("lsp/server.zig");
    _ = @import("lsp/context.zig");
    _ = @import("lsp/helpers.zig");
    _ = @import("lsp/transport.zig");
    _ = @import("lsp/types.zig");
    _ = @import("lsp/builtins.zig");
}
