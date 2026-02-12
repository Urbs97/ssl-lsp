const std = @import("std");

/// LSP Position (0-indexed line and character)
pub const Position = struct {
    line: u32,
    character: u32,

    pub fn toJson(self: Position, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("line", .{ .integer = @intCast(self.line) });
        try obj.put("character", .{ .integer = @intCast(self.character) });
        return .{ .object = obj };
    }
};

/// LSP Range
pub const Range = struct {
    start: Position,
    end: Position,

    pub fn toJson(self: Range, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("start", try self.start.toJson(allocator));
        try obj.put("end", try self.end.toJson(allocator));
        return .{ .object = obj };
    }
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

    pub fn toJson(self: Diagnostic, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("range", try self.range.toJson(allocator));
        try obj.put("severity", .{ .integer = @intFromEnum(self.severity) });
        try obj.put("source", .{ .string = self.source });
        try obj.put("message", .{ .string = self.message });
        return .{ .object = obj };
    }
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

    /// Serialize a DocumentSymbol to a json Value (recursive for children)
    pub fn toJson(self: DocumentSymbol, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("name", .{ .string = self.name });
        if (self.detail) |detail| {
            try obj.put("detail", .{ .string = detail });
        }
        try obj.put("kind", .{ .integer = @intFromEnum(self.kind) });
        try obj.put("range", try self.range.toJson(allocator));
        try obj.put("selectionRange", try self.selection_range.toJson(allocator));
        if (self.children) |children| {
            var arr = std.json.Array.init(allocator);
            for (children) |child| {
                try arr.append(try child.toJson(allocator));
            }
            try obj.put("children", .{ .array = arr });
        }
        return .{ .object = obj };
    }
};

pub const Location = struct {
    uri: []const u8,
    range: Range,

    pub fn toJson(self: Location, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("uri", .{ .string = self.uri });
        try obj.put("range", try self.range.toJson(allocator));
        return .{ .object = obj };
    }
};

pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,

    pub fn toJson(self: MarkupContent, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("kind", .{ .string = self.kind });
        try obj.put("value", .{ .string = self.value });
        return .{ .object = obj };
    }
};

pub const Hover = struct {
    contents: MarkupContent,

    pub fn toJson(self: Hover, allocator: std.mem.Allocator) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("contents", try self.contents.toJson(allocator));
        return .{ .object = obj };
    }
};
