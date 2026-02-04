const std = @import("std");

/// C bindings to libparser.so
pub const c = @cImport({
    @cInclude("parser.h");
});

/// Extract a name from the namespace buffer at the given offset.
/// The format is: 2 bytes length (big-endian at offset-6, offset-5), then string at offset-4
pub fn extractName(namespace: []const u8, name_offset: usize) ?[]const u8 {
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
pub fn varTypeStr(var_type: c_int) []const u8 {
    return switch (var_type) {
        c.V_LOCAL => "local",
        c.V_GLOBAL => "global",
        c.V_IMPORT => "import",
        c.V_EXPORT => "export",
        else => "unknown",
    };
}

/// Get procedure flags as string
pub fn procFlagsStr(flags: c_int, buf: []u8) []const u8 {
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

// Tests

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
