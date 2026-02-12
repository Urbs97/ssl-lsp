const std = @import("std");

const c = @cImport({
    @cInclude("parser.h");
});

pub const VarType = enum {
    local,
    global,
    import_,
    export_,

    pub fn name(self: VarType) []const u8 {
        return switch (self) {
            .local => "local",
            .global => "global",
            .import_ => "import",
            .export_ => "export",
        };
    }
};

pub const ValueType = enum { int, float, string };

pub const ProcFlags = packed struct(u7) {
    timed: bool = false,
    conditional: bool = false,
    import_: bool = false,
    export_: bool = false,
    critical: bool = false,
    pure: bool = false,
    inline_: bool = false,

    pub fn fromRaw(raw: c_int) ProcFlags {
        return @bitCast(@as(u7, @truncate(@as(c_uint, @bitCast(raw)))));
    }

    pub fn format(self: ProcFlags, buf: []u8) []const u8 {
        var pos: usize = 0;

        const flags = .{
            .{ self.timed, "timed " },
            .{ self.conditional, "conditional " },
            .{ self.import_, "import " },
            .{ self.export_, "export " },
            .{ self.critical, "critical " },
            .{ self.pure, "pure " },
            .{ self.inline_, "inline " },
        };

        inline for (flags) |flag| {
            if (flag[0]) {
                const s = flag[1];
                @memcpy(buf[pos..][0..s.len], s);
                pos += s.len;
            }
        }

        if (pos == 0) return "(none)";
        return buf[0 .. pos - 1]; // trim trailing space
    }
};

pub const ParseError = error{ ParseFailed, PreprocessFailed, UnknownError, OutOfMemory };

pub const Reference = struct {
    line: u32,
    file: ?[]const u8,
};

pub const Value = union(ValueType) {
    int: i32,
    float: f32,
    string: u32,
};

pub const Variable = struct {
    name: []const u8,
    var_type: VarType,
    declared_line: u32,
    declared_file: ?[]const u8,
    num_refs: usize,
    array_len: usize,
    uses: usize,
    initialized: bool,
    value: ?Value,
};

pub const Procedure = struct {
    name: []const u8,
    flags: ProcFlags,
    num_args: usize,
    min_args: usize,
    defined: bool,
    declared_line: u32,
    declared_file: ?[]const u8,
    start_line: ?u32,
    start_file: ?[]const u8,
    end_line: ?u32,
    end_file: ?[]const u8,
    num_refs: usize,
    num_local_vars: usize,
    uses: usize,
};

pub const ParseResult = struct {
    allocator: std.mem.Allocator,
    namespace: []const u8,
    stringspace: []const u8,
    proc_namespaces: []?[]const u8,
    num_procs: usize,
    num_vars: usize,

    pub fn deinit(self: *ParseResult) void {
        for (self.proc_namespaces) |maybe_ns| {
            if (maybe_ns) |ns| self.allocator.free(ns);
        }
        self.allocator.free(self.proc_namespaces);
        if (self.namespace.len > 0) self.allocator.free(self.namespace);
        if (self.stringspace.len > 0) self.allocator.free(self.stringspace);
    }

    pub fn getProc(self: *const ParseResult, index: usize) Procedure {
        var raw: c.Procedure = undefined;
        c.getProc(@intCast(index), &raw);
        return translateProc(self.namespace, raw);
    }

    pub fn getVar(self: *const ParseResult, index: usize) Variable {
        var raw: c.Variable = undefined;
        c.getVar(@intCast(index), &raw);
        return translateVar(self.namespace, raw);
    }

    pub fn getProcVar(self: *ParseResult, proc_index: usize, var_index: usize) Variable {
        var raw: c.Variable = undefined;
        c.getProcVar(@intCast(proc_index), @intCast(var_index), &raw);
        const ns = self.loadProcNamespace(proc_index);
        return translateVar(ns, raw);
    }

    pub fn getProcRefs(_: *const ParseResult, proc_index: usize, allocator: std.mem.Allocator) ![]Reference {
        var raw: c.Procedure = undefined;
        c.getProc(@intCast(proc_index), &raw);
        const count: usize = @intCast(raw.numRefs);
        if (count == 0) return &.{};

        const refs = try allocator.alloc(c.Reference, count);
        defer allocator.free(refs);
        c.getProcRefs(@intCast(proc_index), refs.ptr);

        const result = try allocator.alloc(Reference, count);
        for (refs, 0..) |r, idx| {
            result[idx] = .{
                .line = @intCast(r.line),
                .file = spanOptional(r.file),
            };
        }
        return result;
    }

    pub fn getVarRefs(_: *const ParseResult, var_index: usize, allocator: std.mem.Allocator) ![]Reference {
        var raw: c.Variable = undefined;
        c.getVar(@intCast(var_index), &raw);
        const count: usize = @intCast(raw.numRefs);
        if (count == 0) return &.{};

        const refs = try allocator.alloc(c.Reference, count);
        defer allocator.free(refs);
        c.getVarRefs(@intCast(var_index), refs.ptr);

        const result = try allocator.alloc(Reference, count);
        for (refs, 0..) |r, idx| {
            result[idx] = .{
                .line = @intCast(r.line),
                .file = spanOptional(r.file),
            };
        }
        return result;
    }

    pub fn getStringValue(self: *const ParseResult, offset: u32) ?[]const u8 {
        return extractName(self.stringspace, @intCast(offset));
    }

    pub fn getProcVarRefs(_: *ParseResult, proc_index: usize, var_index: usize, allocator: std.mem.Allocator) ![]Reference {
        var raw: c.Variable = undefined;
        c.getProcVar(@intCast(proc_index), @intCast(var_index), &raw);
        const count: usize = @intCast(raw.numRefs);
        if (count == 0) return &.{};

        const refs = try allocator.alloc(c.Reference, count);
        defer allocator.free(refs);
        c.getProcVarRefs(@intCast(proc_index), @intCast(var_index), refs.ptr);

        const result = try allocator.alloc(Reference, count);
        for (refs, 0..) |r, idx| {
            result[idx] = .{
                .line = @intCast(r.line),
                .file = spanOptional(r.file),
            };
        }
        return result;
    }

    fn loadProcNamespace(self: *ParseResult, proc_index: usize) []const u8 {
        if (self.proc_namespaces[proc_index]) |ns| return ns;

        const size = c.getProcNamespaceSize(@intCast(proc_index));
        if (size <= 0) return &.{};

        const buf = self.allocator.alloc(u8, @intCast(size)) catch return &.{};
        c.getProcNamespace(@intCast(proc_index), buf.ptr);
        self.proc_namespaces[proc_index] = buf;
        return buf;
    }
};

pub fn parse(allocator: std.mem.Allocator, file_path: []const u8, orig_path: []const u8, dir: []const u8) ParseError!ParseResult {
    // Create null-terminated copies for C API
    const c_file = try allocator.dupeZ(u8, file_path);
    defer allocator.free(c_file);
    const c_orig = try allocator.dupeZ(u8, orig_path);
    defer allocator.free(c_orig);
    const c_dir = try allocator.dupeZ(u8, dir);
    defer allocator.free(c_dir);

    const result = c.parse_main(c_file.ptr, c_orig.ptr, c_dir.ptr);
    if (result != 0) {
        return switch (result) {
            1 => error.ParseFailed,
            2 => error.PreprocessFailed,
            else => error.UnknownError,
        };
    }

    // Fetch namespace
    const ns_size = c.namespaceSize();
    const namespace: []const u8 = if (ns_size > 0) blk: {
        const buf = try allocator.alloc(u8, @intCast(ns_size));
        c.getNamespace(buf.ptr);
        break :blk buf;
    } else &.{};
    errdefer if (namespace.len > 0) allocator.free(namespace);

    // Fetch stringspace
    const str_size = c.stringspaceSize();
    const stringspace: []const u8 = if (str_size > 0) blk: {
        const buf = try allocator.alloc(u8, @intCast(str_size));
        c.getStringspace(buf.ptr);
        break :blk buf;
    } else &.{};
    errdefer if (stringspace.len > 0) allocator.free(stringspace);

    const num_procs: usize = @intCast(c.numProcs());
    const num_vars: usize = @intCast(c.numVars());

    // Allocate proc_namespaces array (all null initially, loaded lazily)
    const proc_namespaces = try allocator.alloc(?[]const u8, num_procs);
    @memset(proc_namespaces, null);

    return .{
        .allocator = allocator,
        .namespace = namespace,
        .stringspace = stringspace,
        .proc_namespaces = proc_namespaces,
        .num_procs = num_procs,
        .num_vars = num_vars,
    };
}

/// Convert a nullable C string pointer to an optional Zig slice
fn spanOptional(ptr: ?[*:0]const u8) ?[]const u8 {
    const p = ptr orelse return null;
    return std.mem.span(p);
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

/// Translate a raw C Variable to Zig Variable type
fn translateVar(namespace: []const u8, raw: c.Variable) Variable {
    return .{
        .name = if (namespace.len > 0)
            extractName(namespace, @intCast(raw.name)) orelse "<invalid>"
        else
            "<no namespace>",
        .var_type = switch (raw.type) {
            c.V_LOCAL => .local,
            c.V_GLOBAL => .global,
            c.V_IMPORT => .import_,
            c.V_EXPORT => .export_,
            else => .local,
        },
        .declared_line = @intCast(raw.declared),
        .declared_file = spanOptional(raw.fdeclared),
        .num_refs = @intCast(raw.numRefs),
        .array_len = if (raw.arrayLen > 0) @intCast(raw.arrayLen) else 0,
        .uses = @intCast(raw.uses),
        .initialized = raw.initialized != 0,
        .value = translateValue(raw.value),
    };
}

/// Translate a raw C Value to Zig Value type
fn translateValue(raw: c.Value) ?Value {
    return switch (raw.type) {
        c.V_INT => .{ .int = raw.unnamed_0.intData },
        c.V_FLOAT => .{ .float = raw.unnamed_0.floatData },
        c.V_STRING => .{ .string = @intCast(raw.unnamed_0.stringData) },
        else => null,
    };
}

/// Translate a raw C Procedure to Zig Procedure type
fn translateProc(namespace: []const u8, raw: c.Procedure) Procedure {
    return .{
        .name = if (namespace.len > 0)
            extractName(namespace, @intCast(raw.name)) orelse "<invalid>"
        else
            "<no namespace>",
        .flags = ProcFlags.fromRaw(raw.type),
        .num_args = @intCast(raw.numArgs),
        .min_args = @intCast(raw.minArgs),
        .defined = raw.defined != 0,
        .declared_line = @intCast(raw.declared),
        .declared_file = spanOptional(raw.fdeclared),
        .start_line = if (raw.defined != 0) @as(u32, @intCast(raw.start)) else null,
        .start_file = if (raw.defined != 0) spanOptional(raw.fstart) else null,
        .end_line = if (raw.defined != 0) @as(u32, @intCast(raw.end)) else null,
        .end_file = if (raw.defined != 0) spanOptional(raw.fend) else null,
        .num_refs = @intCast(raw.numRefs),
        .num_local_vars = @intCast(raw.variables.numVariables),
        .uses = @intCast(raw.uses),
    };
}

test "parser API functions exist" {
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
    var result = try parse(std.testing.allocator, "test/minimal.ssl", "test/minimal.ssl", "test");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.num_procs);
    try std.testing.expectEqual(@as(usize, 1), result.num_vars);
}

test "parse standalone script" {
    var result = try parse(std.testing.allocator, "test/standalone.ssl", "test/standalone.ssl", "test");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 7), result.num_procs);
    try std.testing.expectEqual(@as(usize, 4), result.num_vars);
    try std.testing.expect(result.namespace.len > 0);

    // Verify procedure info
    var proc = result.getProc(0);
    try std.testing.expectEqual(@as(usize, 0), proc.num_args); // helper_proc has no args
    try std.testing.expectEqual(@as(usize, 1), proc.num_local_vars); // 1 local var

    proc = result.getProc(1);
    try std.testing.expectEqual(@as(usize, 2), proc.num_args); // calculate has 2 args

    proc = result.getProc(2);
    try std.testing.expect(proc.flags.pure); // double_value is pure

    proc = result.getProc(3);
    try std.testing.expect(proc.flags.inline_); // add_to_counter is inline
}
