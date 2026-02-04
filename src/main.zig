const std = @import("std");
const c = @cImport({
    @cInclude("parser.h");
});

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
    const allocator = std.heap.page_allocator;

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

    if (result != 0) {
        std.debug.print("Parse failed with code: {d}\n", .{result});
        return;
    }

    std.debug.print("Parse successful!\n\n", .{});

    // Get namespace for name lookups
    const ns_size = c.namespaceSize();
    std.debug.print("Namespace size: {d} bytes\n", .{ns_size});

    var namespace: []u8 = &.{};
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
