const std = @import("std");

/// LSP Position (0-indexed line and character)
pub const Position = struct {
    line: u32,
    character: u32,
};

/// LSP Range
pub const Range = struct {
    start: Position,
    end: Position,
};

pub const DiagnosticSeverity = enum(u8) {
    Error = 1,
    Warning = 2,
    Information = 3,
    Hint = 4,
};

pub const Diagnostic = struct {
    range: Range,
    severity: DiagnosticSeverity,
    message: []const u8,
    source: []const u8 = "ssl-lsp",
};

/// Serialize a Diagnostic to a json Value
pub fn diagnosticToJson(allocator: std.mem.Allocator, diag: Diagnostic) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);

    // range
    var range_obj = std.json.ObjectMap.init(allocator);
    var start_obj = std.json.ObjectMap.init(allocator);
    try start_obj.put("line", .{ .integer = @intCast(diag.range.start.line) });
    try start_obj.put("character", .{ .integer = @intCast(diag.range.start.character) });
    try range_obj.put("start", .{ .object = start_obj });

    var end_obj = std.json.ObjectMap.init(allocator);
    try end_obj.put("line", .{ .integer = @intCast(diag.range.end.line) });
    try end_obj.put("character", .{ .integer = @intCast(diag.range.end.character) });
    try range_obj.put("end", .{ .object = end_obj });

    try obj.put("range", .{ .object = range_obj });

    // severity
    try obj.put("severity", .{ .integer = @intFromEnum(diag.severity) });

    // source
    try obj.put("source", .{ .string = diag.source });

    // message
    try obj.put("message", .{ .string = diag.message });

    return .{ .object = obj };
}
