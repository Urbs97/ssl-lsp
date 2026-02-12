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

pub const SymbolKind = enum(u8) {
    Function = 12,
    Variable = 13,
};

pub const DocumentSymbol = struct {
    name: []const u8,
    detail: ?[]const u8 = null,
    kind: SymbolKind,
    range: Range,
    selection_range: Range,
    children: ?[]const DocumentSymbol = null,
};

pub const Location = struct {
    uri: []const u8,
    range: Range,
};

pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

pub const Hover = struct {
    contents: MarkupContent,
};

/// Serialize an LSP Position to a json Value
fn positionToJson(allocator: std.mem.Allocator, pos: Position) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("line", .{ .integer = @intCast(pos.line) });
    try obj.put("character", .{ .integer = @intCast(pos.character) });
    return .{ .object = obj };
}

/// Serialize an LSP Range to a json Value
pub fn rangeToJson(allocator: std.mem.Allocator, range: Range) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("start", try positionToJson(allocator, range.start));
    try obj.put("end", try positionToJson(allocator, range.end));
    return .{ .object = obj };
}

/// Serialize an LSP Location to a json Value
pub fn locationToJson(allocator: std.mem.Allocator, loc: Location) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("uri", .{ .string = loc.uri });
    try obj.put("range", try rangeToJson(allocator, loc.range));
    return .{ .object = obj };
}

fn markupContentToJson(allocator: std.mem.Allocator, mc: MarkupContent) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("kind", .{ .string = mc.kind });
    try obj.put("value", .{ .string = mc.value });
    return .{ .object = obj };
}

/// Serialize an LSP Hover to a json Value
pub fn hoverToJson(allocator: std.mem.Allocator, hover: Hover) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);
    try obj.put("contents", try markupContentToJson(allocator, hover.contents));
    return .{ .object = obj };
}

/// Serialize a Diagnostic to a json Value
pub fn diagnosticToJson(allocator: std.mem.Allocator, diag: Diagnostic) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);

    try obj.put("range", try rangeToJson(allocator, diag.range));
    try obj.put("severity", .{ .integer = @intFromEnum(diag.severity) });
    try obj.put("source", .{ .string = diag.source });
    try obj.put("message", .{ .string = diag.message });

    return .{ .object = obj };
}

/// Serialize a DocumentSymbol to a json Value (recursive for children)
pub fn documentSymbolToJson(allocator: std.mem.Allocator, sym: DocumentSymbol) !std.json.Value {
    var obj = std.json.ObjectMap.init(allocator);

    try obj.put("name", .{ .string = sym.name });
    if (sym.detail) |detail| {
        try obj.put("detail", .{ .string = detail });
    }
    try obj.put("kind", .{ .integer = @intFromEnum(sym.kind) });
    try obj.put("range", try rangeToJson(allocator, sym.range));
    try obj.put("selectionRange", try rangeToJson(allocator, sym.selection_range));

    if (sym.children) |children| {
        var arr = std.json.Array.init(allocator);
        for (children) |child| {
            try arr.append(try documentSymbolToJson(allocator, child));
        }
        try obj.put("children", .{ .array = arr });
    }

    return .{ .object = obj };
}
