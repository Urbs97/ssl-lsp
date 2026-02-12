const std = @import("std");
const helpers = @import("helpers.zig");

pub const Opcode = struct {
    name: []const u8,
    signature: []const u8,
    description: []const u8,
};

const embedded_data = @embedFile("../resources/opcodes.txt");

var opcodes_list: std.ArrayListUnmanaged(Opcode) = .empty;

pub fn init(allocator: std.mem.Allocator) !void {
    // Use a temporary hash map for deduplication (later entries override earlier)
    var dedup = std.StringHashMapUnmanaged(Opcode){};
    defer dedup.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, embedded_data, '\n');
    while (line_iter.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        // Skip empty lines
        if (trimmed.len == 0) continue;
        // Skip comments
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        // Skip redefinition lines
        if (std.mem.startsWith(u8, trimmed, "redefinition")) continue;

        // Split at first " - " to separate signature from description
        var signature: []const u8 = trimmed;
        var description: []const u8 = "";
        if (std.mem.indexOf(u8, trimmed, " - ")) |sep_idx| {
            signature = trimmed[0..sep_idx];
            description = trimmed[sep_idx + 3 ..];
        }

        // Strip trailing ':'  from signature
        signature = std.mem.trimRight(u8, signature, ":");

        // Extract name from signature
        const name = extractName(signature) orelse continue;

        // Merge with existing: later entries override, but keep old fields
        // when the new entry lacks them
        const gop = try dedup.getOrPut(allocator, name);
        if (gop.found_existing) {
            const existing = gop.value_ptr;
            existing.signature = signature;
            if (description.len > 0) {
                existing.description = description;
            }
        } else {
            gop.value_ptr.* = .{
                .name = name,
                .signature = signature,
                .description = description,
            };
        }
    }

    // Copy deduped entries into the final list
    try opcodes_list.ensureTotalCapacity(allocator, dedup.count());
    var it = dedup.valueIterator();
    while (it.next()) |val| {
        opcodes_list.appendAssumeCapacity(val.*);
    }
}

pub fn deinit(allocator: std.mem.Allocator) void {
    opcodes_list.deinit(allocator);
    opcodes_list = .empty;
}

pub fn opcodes() []const Opcode {
    return opcodes_list.items;
}

/// Extract the function/property name from a signature string.
/// For signatures with parentheses like "int random(int min, int max)", find the
/// identifier before the last '('.
/// For property-style like "ObjectPtr dude_obj", take the last identifier token.
fn extractName(signature: []const u8) ?[]const u8 {
    // Find the last '(' — the name is the identifier just before it
    if (std.mem.lastIndexOfScalar(u8, signature, '(')) |paren_idx| {
        // Scan backwards past whitespace from just before '('
        var end = paren_idx;
        while (end > 0 and signature[end - 1] == ' ') {
            end -= 1;
        }
        if (end == 0) return null;

        // Scan backwards to find the start of the identifier
        var start = end;
        while (start > 0 and helpers.isIdentChar(signature[start - 1])) {
            start -= 1;
        }
        if (start == end) return null;
        return signature[start..end];
    }

    // No parentheses — property-style: take last identifier token
    const trimmed = std.mem.trimRight(u8, signature, " \t");
    if (trimmed.len == 0) return null;

    var end = trimmed.len;
    while (end > 0 and !helpers.isIdentChar(trimmed[end - 1])) {
        end -= 1;
    }
    if (end == 0) return null;

    var start = end;
    while (start > 0 and helpers.isIdentChar(trimmed[start - 1])) {
        start -= 1;
    }
    if (start == end) return null;
    return trimmed[start..end];
}

test "builtins init and lookup" {
    const allocator = std.testing.allocator;
    try init(allocator);
    defer deinit(allocator);

    const ops = opcodes();
    // Should have a reasonable number of opcodes
    try std.testing.expect(ops.len > 100);

    // Check that 'random' is present
    var found_random = false;
    for (ops) |op| {
        if (std.mem.eql(u8, op.name, "random")) {
            found_random = true;
            // Should have a description
            try std.testing.expect(op.description.len > 0);
            break;
        }
    }
    try std.testing.expect(found_random);
}
