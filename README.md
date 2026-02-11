# ssl-lsp

A Language Server and linter for Fallout SSL (Star-Trek Scripting Language) scripts, written in Zig.

## Features

- **Linting** - Parse SSL scripts and report syntax errors, warnings, and diagnostics
- **LSP Server** - Language Server Protocol support over stdio for editor integration
  - Real-time diagnostics (syntax errors as you type)

### Planned

- Document symbols (procedure/variable outline)
- Go to definition
- Find references
- Hover information
- Completion and signature help for built-in opcodes

## Requirements

- [Zig](https://ziglang.org/) (version 0.15)
- Linux x86 (32-bit) (Windows support is planned)

## Building

```bash
git clone --recursive https://github.com/Urbs97/ssl-lsp.git
cd ssl-lsp
zig build
```

The binary is output to `zig-out/bin/ssl-lsp`.

For optimized builds:

```bash
zig build --release=fast
```

## Usage

### Lint a script

```bash
ssl-lsp --lint script.ssl
```

### Start the LSP server

```bash
ssl-lsp --stdio
```

## Editor Setup

### Neovim

Register the `.ssl` filetype and configure the LSP server:

```lua
vim.filetype.add({
  extension = {
    ssl = 'ssl',
  },
})

vim.lsp.config('ssl_lsp', {
  cmd = { '/path/to/zig-out/bin/ssl-lsp', '--stdio' },
  filetypes = { 'ssl' },
  root_markers = { '.git' },
})
vim.lsp.enable('ssl_lsp')
```

## Architecture

```
SSL Script → sslc (C parser) → Zig FFI → LSP / CLI Output
```

The project builds [sslc](https://github.com/sfall-team/sslc) from source as a static C library and links it via Zig's C interop. The parser provides procedure/variable extraction, reference tracking, and AST data used to power the LSP features.

```
src/
├── main.zig           # Entry point — dispatches --lint / --stdio
├── parsing/
│   ├── parser.zig     # C FFI bindings to sslc
│   └── errors.zig     # Diagnostic parsing
└── lsp/
    ├── server.zig     # LSP message loop
    ├── transport.zig  # JSON-RPC framing
    └── types.zig      # LSP protocol types
```

## Testing

```bash
zig build test
```

## License

[GPL-3.0](LICENSE)
