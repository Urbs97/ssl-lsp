const std = @import("std");
const Context = @import("../context.zig").Context;
const helpers = @import("../helpers.zig");
const types = @import("../types.zig");
const builtins = @import("../builtins.zig");
const defines_mod = @import("../defines.zig");

const log = std.log.scoped(.server);

pub fn handle(ctx: *Context, allocator: std.mem.Allocator, id: ?std.json.Value, params: std.json.Value) anyerror!void {
    const req_id = id orelse return;

    const uri = helpers.getTextDocumentUri(params) orelse {
        log.err("signatureHelp: missing textDocument.uri", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };
    const pos = helpers.getPosition(params) orelse {
        log.err("signatureHelp: missing position params", .{});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    const doc = ctx.documents.getPtr(uri) orelse {
        log.debug("signatureHelp: unknown document {s}", .{uri});
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    const call_ctx = helpers.getCallContext(doc.text, @intCast(pos.line), @intCast(pos.character)) orelse {
        try ctx.sendResponse(allocator, req_id, .null);
        return;
    };

    // Search built-in opcodes
    for (builtins.opcodes()) |op| {
        if (std.ascii.eqlIgnoreCase(op.name, call_ctx.func_name)) {
            const param_strings = helpers.parseSignatureParams(allocator, op.signature) orelse {
                // Property-style opcode with no parens — no signature help
                try ctx.sendResponse(allocator, req_id, .null);
                return;
            };

            const param_infos = try allocator.alloc(types.ParameterInformation, param_strings.len);
            for (param_strings, 0..) |ps, i| {
                param_infos[i] = .{ .label = ps };
            }

            const active_param = if (param_strings.len > 0)
                @min(call_ctx.active_param, @as(u32, @intCast(param_strings.len - 1)))
            else
                0;

            const sig = types.SignatureInformation{
                .label = op.signature,
                .documentation = if (op.description.len > 0) .{ .value = op.description } else null,
                .parameters = param_infos,
                .activeParameter = active_param,
            };
            const sigs = try allocator.alloc(types.SignatureInformation, 1);
            sigs[0] = sig;

            const result = types.SignatureHelp{
                .signatures = sigs,
                .activeSignature = 0,
                .activeParameter = active_param,
            };
            try ctx.sendResponse(allocator, req_id, try result.toJson(allocator));
            return;
        }
    }

    // Search user-defined procedures
    if (doc.parse_result) |*pr| {
        for (0..pr.num_procs) |i| {
            const proc = pr.getProc(i);
            if (std.ascii.eqlIgnoreCase(proc.name, call_ctx.func_name)) {
                // Build label: "procedure name(arg1, arg2, ...)"
                var out: std.Io.Writer.Allocating = .init(allocator);
                const w = &out.writer;
                try w.writeAll("procedure ");
                try w.writeAll(proc.name);
                try w.writeByte('(');

                const param_infos = try allocator.alloc(types.ParameterInformation, proc.num_args);
                for (0..proc.num_args) |a| {
                    if (a > 0) try w.writeAll(", ");
                    const arg_var = pr.getProcVar(i, a);
                    param_infos[a] = .{ .label = arg_var.name };
                    try w.writeAll(arg_var.name);
                }
                try w.writeByte(')');

                const label = out.written();

                const active_param = if (proc.num_args > 0)
                    @min(call_ctx.active_param, @as(u32, @intCast(proc.num_args - 1)))
                else
                    0;

                // Extract doc comment
                const doc_comment = try helpers.extractDocComment(allocator, doc.text, proc.declared_line);
                const documentation: ?types.MarkupContent = if (doc_comment) |dc| .{ .value = dc } else null;

                const sig = types.SignatureInformation{
                    .label = label,
                    .documentation = documentation,
                    .parameters = param_infos,
                    .activeParameter = active_param,
                };
                const sigs = try allocator.alloc(types.SignatureInformation, 1);
                sigs[0] = sig;

                const result = types.SignatureHelp{
                    .signatures = sigs,
                    .activeSignature = 0,
                    .activeParameter = active_param,
                };
                try ctx.sendResponse(allocator, req_id, try result.toJson(allocator));
                return;
            }
        }
    }

    // Search #define macros
    if (doc.defines) |*defs| {
        if (defs.lookupCaseInsensitive(call_ctx.func_name)) |def| {
            if (def.params) |def_params| {
                if (def_params.len > 0) {
                    // Build label: "name(param1, param2)"
                    var out: std.Io.Writer.Allocating = .init(allocator);
                    const w = &out.writer;
                    try w.writeAll(def.name);
                    try w.writeByte('(');
                    const param_infos = try allocator.alloc(types.ParameterInformation, def_params.len);
                    for (def_params, 0..) |p, i| {
                        if (i > 0) try w.writeAll(", ");
                        param_infos[i] = .{ .label = p };
                        try w.writeAll(p);
                    }
                    try w.writeByte(')');

                    const label = out.written();

                    const active_param = @min(call_ctx.active_param, @as(u32, @intCast(def_params.len - 1)));

                    const documentation: ?types.MarkupContent = if (def.doc_comment) |dc| .{ .value = dc } else null;

                    const sig = types.SignatureInformation{
                        .label = label,
                        .documentation = documentation,
                        .parameters = param_infos,
                        .activeParameter = active_param,
                    };
                    const sigs = try allocator.alloc(types.SignatureInformation, 1);
                    sigs[0] = sig;

                    const result = types.SignatureHelp{
                        .signatures = sigs,
                        .activeSignature = 0,
                        .activeParameter = active_param,
                    };
                    try ctx.sendResponse(allocator, req_id, try result.toJson(allocator));
                    return;
                }
            }
        }
    }

    // No match found
    try ctx.sendResponse(allocator, req_id, .null);
}
