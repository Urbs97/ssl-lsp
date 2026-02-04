const std = @import("std");
const parser = @import("parser.zig");
const errors = @import("errors.zig");

const c = parser.c;

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
    const parse_errors = try errors.readErrors(allocator);
    defer errors.freeErrors(allocator, parse_errors);

    if (result != 0) {
        std.debug.print("Parse failed with code: {d}\n", .{result});
        // 0 = success, 1 = parse error, 2+ = preprocess error
        const result_desc: []const u8 = switch (result) {
            1 => " (parse error)",
            2 => " (preprocess error)",
            else => "",
        };
        std.debug.print("Exit code: {d}{s}\n", .{ result, result_desc });
        errors.displayErrors(parse_errors);
        return;
    }

    std.debug.print("Parse successful!\n", .{});

    // Display any warnings/messages even on success
    if (parse_errors.len > 0) {
        errors.displayErrors(parse_errors);
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
            parser.extractName(namespace, @intCast(proc.name)) orelse "<invalid>"
        else
            "<no namespace>";

        var flags_buf: [128]u8 = undefined;
        const flags = parser.procFlagsStr(proc.type, &flags_buf);

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

                    const var_name = parser.extractName(proc_ns, @intCast(local_var.name)) orelse "<invalid>";
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
            parser.extractName(namespace, @intCast(variable.name)) orelse "<invalid>"
        else
            "<no namespace>";

        const var_type = parser.varTypeStr(variable.type);

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

// Import tests from submodules
test {
    _ = @import("parser.zig");
    _ = @import("errors.zig");
}
