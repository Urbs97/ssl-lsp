# Code Style

Follow the default Zig style guide: https://ziglang.org/documentation/master/#Style-Guide

## Logging

Always use `std.log` (via `std.log.scoped`) for all logging. Never write diagnostic or debug output to stdout. In LSP mode, stdout is reserved exclusively for JSON-RPC protocol traffic. `std.log` writes to stderr by default, keeping the protocol channel clean.

```zig
const log = std.log.scoped(.my_module);

log.info("something happened", .{});   // goes to stderr
log.err("something broke: {}", .{err}); // goes to stderr
```

Log levels for each scope are configured in `src/main.zig` via `std_options.log_scope_levels`.
