const std = @import("std");
const Context = @import("../context.zig").Context;

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, id: ?std.json.Value, _: std.json.Value) anyerror!void {
    const req_id = id orelse return;

    var capabilities = std.json.ObjectMap.init(allocator);
    try capabilities.put("textDocumentSync", .{ .integer = 1 });
    try capabilities.put("documentSymbolProvider", .{ .bool = true });
    try capabilities.put("definitionProvider", .{ .bool = true });
    try capabilities.put("referencesProvider", .{ .bool = true });
    try capabilities.put("hoverProvider", .{ .bool = true });

    const completion_options = std.json.ObjectMap.init(allocator);
    try capabilities.put("completionProvider", .{ .object = completion_options });

    var sig_help_options = std.json.ObjectMap.init(allocator);
    var trigger_chars = std.json.Array.init(allocator);
    try trigger_chars.append(.{ .string = "(" });
    try trigger_chars.append(.{ .string = "," });
    try sig_help_options.put("triggerCharacters", .{ .array = trigger_chars });
    try capabilities.put("signatureHelpProvider", .{ .object = sig_help_options });

    var result = std.json.ObjectMap.init(allocator);
    try result.put("capabilities", .{ .object = capabilities });

    var server_info = std.json.ObjectMap.init(allocator);
    try server_info.put("name", .{ .string = "ssl-lsp" });
    try server_info.put("version", .{ .string = "0.1.0" });
    try result.put("serverInfo", .{ .object = server_info });

    try ctx.sendResponse(allocator, req_id, .{ .object = result });
    log.info("initialized", .{});
}
