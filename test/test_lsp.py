#!/usr/bin/env python3
"""Integration tests for the ssl-lsp LSP server."""

import json
import subprocess
import sys
import os

LSP_BIN = os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin", "ssl-lsp")


def make_msg(obj):
    """Encode a JSON-RPC message with Content-Length header."""
    body = json.dumps(obj)
    return f"Content-Length: {len(body)}\r\n\r\n{body}".encode()


def parse_responses(raw_stdout):
    """Parse raw LSP stdout into a list of JSON objects."""
    messages = []
    data = raw_stdout.decode()
    while data:
        if not data.startswith("Content-Length: "):
            break
        header_end = data.index("\r\n\r\n")
        length = int(data[len("Content-Length: "):header_end])
        body_start = header_end + 4
        body = data[body_start:body_start + length]
        messages.append(json.loads(body))
        data = data[body_start + length:]
    return messages


def run_lsp(*messages):
    """Send a sequence of JSON-RPC messages and return parsed responses."""
    stdin_data = b"".join(make_msg(m) for m in messages)
    result = subprocess.run(
        [LSP_BIN, "--stdio"],
        input=stdin_data,
        capture_output=True,
        timeout=10,
    )
    return parse_responses(result.stdout), result.stderr.decode(), result.returncode


def init_messages():
    """Return the standard initialize + initialized handshake messages."""
    return [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"capabilities": {}}},
        {"jsonrpc": "2.0", "method": "initialized", "params": {}},
    ]


def shutdown_messages(next_id=100):
    """Return shutdown + exit messages."""
    return [
        {"jsonrpc": "2.0", "id": next_id, "method": "shutdown", "params": {}},
        {"jsonrpc": "2.0", "method": "exit"},
    ]


def test_initialize():
    """Server responds to initialize with capabilities."""
    responses, stderr, code = run_lsp(*init_messages(), *shutdown_messages())

    init_response = responses[0]
    assert init_response["id"] == 1
    assert "result" in init_response

    caps = init_response["result"]["capabilities"]
    assert caps["textDocumentSync"] == 1
    assert caps["documentSymbolProvider"] is True, f"Expected documentSymbolProvider, got: {caps}"
    assert "completionProvider" in caps, f"Expected completionProvider, got: {caps}"

    info = init_response["result"]["serverInfo"]
    assert info["name"] == "ssl-lsp"

    print("PASS: test_initialize")


def test_diagnostics_on_bad_ssl():
    """Opening a file with invalid SSL produces error diagnostics."""
    bad_ssl = "this is not valid ssl code at all;\n"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": "file:///tmp/test_bad.ssl",
                "languageId": "ssl",
                "version": 1,
                "text": bad_ssl,
            }
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, *shutdown_messages())

    # Find the publishDiagnostics notification
    diag_msgs = [r for r in responses if r.get("method") == "textDocument/publishDiagnostics"]
    assert len(diag_msgs) >= 1, f"Expected diagnostics, got: {responses}"

    diags = diag_msgs[0]["params"]["diagnostics"]
    assert len(diags) > 0, "Expected at least one diagnostic for invalid SSL"

    # Should have at least one error-level diagnostic (severity 1)
    errors = [d for d in diags if d["severity"] == 1]
    assert len(errors) > 0, f"Expected error diagnostics, got: {diags}"

    # Verify diagnostic structure
    for d in diags:
        assert "range" in d
        assert "start" in d["range"]
        assert "end" in d["range"]
        assert "line" in d["range"]["start"]
        assert "character" in d["range"]["start"]
        assert "message" in d
        assert d["source"] == "ssl-lsp"

    print(f"PASS: test_diagnostics_on_bad_ssl ({len(diags)} diagnostic(s))")
    for d in diags:
        sev = {1: "ERROR", 2: "WARN", 3: "INFO", 4: "HINT"}.get(d["severity"], "?")
        line = d["range"]["start"]["line"]
        col = d["range"]["start"]["character"]
        print(f"  [{sev}] {line}:{col}: {d['message'].strip()}")


def test_diagnostics_on_valid_ssl():
    """Opening a valid SSL file produces empty diagnostics."""
    valid_ssl = "variable count := 0;\n\nprocedure start begin\n    count := 1;\nend\n"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": "file:///tmp/test_good.ssl",
                "languageId": "ssl",
                "version": 1,
                "text": valid_ssl,
            }
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, *shutdown_messages())

    diag_msgs = [r for r in responses if r.get("method") == "textDocument/publishDiagnostics"]
    assert len(diag_msgs) >= 1, f"Expected diagnostics notification, got: {responses}"

    diags = diag_msgs[0]["params"]["diagnostics"]
    errors = [d for d in diags if d["severity"] == 1]
    assert len(errors) == 0, f"Expected no errors for valid SSL, got: {errors}"

    print(f"PASS: test_diagnostics_on_valid_ssl ({len(diags)} diagnostic(s))")


def test_did_change_updates_diagnostics():
    """Changing document content re-publishes diagnostics."""
    valid_ssl = "variable x := 0;\n\nprocedure start begin\n    x := 1;\nend\n"
    bad_ssl = "this is broken\n"

    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": "file:///tmp/test_change.ssl",
                "languageId": "ssl",
                "version": 1,
                "text": valid_ssl,
            }
        },
    }

    did_change = {
        "jsonrpc": "2.0",
        "method": "textDocument/didChange",
        "params": {
            "textDocument": {"uri": "file:///tmp/test_change.ssl", "version": 2},
            "contentChanges": [{"text": bad_ssl}],
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, did_change, *shutdown_messages())

    diag_msgs = [r for r in responses if r.get("method") == "textDocument/publishDiagnostics"]
    assert len(diag_msgs) >= 2, f"Expected 2 diagnostics notifications (open + change), got {len(diag_msgs)}"

    # Second diagnostics should have errors (from the bad change)
    second_diags = diag_msgs[1]["params"]["diagnostics"]
    errors = [d for d in second_diags if d["severity"] == 1]
    assert len(errors) > 0, f"Expected errors after bad change, got: {second_diags}"

    print(f"PASS: test_did_change_updates_diagnostics ({len(second_diags)} diagnostic(s) after change)")


def test_shutdown_response():
    """Shutdown returns null result."""
    responses, stderr, code = run_lsp(*init_messages(), *shutdown_messages(next_id=42))

    shutdown_resp = [r for r in responses if r.get("id") == 42]
    assert len(shutdown_resp) == 1, f"Expected shutdown response, got: {responses}"
    assert shutdown_resp[0]["result"] is None

    print("PASS: test_shutdown_response")


def test_unknown_method():
    """Unknown methods get MethodNotFound error."""
    unknown = {"jsonrpc": "2.0", "id": 99, "method": "custom/nonexistent", "params": {}}

    responses, stderr, code = run_lsp(*init_messages(), unknown, *shutdown_messages())

    err_resp = [r for r in responses if r.get("id") == 99]
    assert len(err_resp) == 1, f"Expected error response for unknown method, got: {responses}"
    assert "error" in err_resp[0]
    assert err_resp[0]["error"]["code"] == -32601

    print("PASS: test_unknown_method")


def test_document_symbols():
    """documentSymbol returns procedures and variables for valid SSL."""
    valid_ssl = "variable count := 0;\n\nprocedure start begin\n    variable localvar;\n    count := 1;\nend\n"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": "file:///tmp/test_symbols.ssl",
                "languageId": "ssl",
                "version": 1,
                "text": valid_ssl,
            }
        },
    }
    doc_symbol_req = {
        "jsonrpc": "2.0",
        "id": 10,
        "method": "textDocument/documentSymbol",
        "params": {
            "textDocument": {"uri": "file:///tmp/test_symbols.ssl"},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, doc_symbol_req, *shutdown_messages())

    symbol_resp = [r for r in responses if r.get("id") == 10]
    assert len(symbol_resp) == 1, f"Expected documentSymbol response, got: {responses}"
    assert "result" in symbol_resp[0], f"Expected result, got: {symbol_resp[0]}"

    symbols = symbol_resp[0]["result"]
    assert isinstance(symbols, list), f"Expected array result, got: {type(symbols)}"
    assert len(symbols) > 0, "Expected at least one symbol"

    # Find the procedure symbol (kind=12 is Function)
    funcs = [s for s in symbols if s["kind"] == 12]
    assert len(funcs) >= 1, f"Expected at least one function symbol, got: {symbols}"

    # Check structure of the function symbol
    func = funcs[0]
    assert func["name"] == "start", f"Expected 'start' proc, got: {func['name']}"
    assert "range" in func
    assert "selectionRange" in func
    assert "start" in func["range"]
    assert "end" in func["range"]

    # Check children (local variables)
    if "children" in func and func["children"]:
        child = func["children"][0]
        assert child["kind"] == 13, f"Expected Variable kind (13), got: {child['kind']}"
        assert child["name"] == "localvar", f"Expected 'localvar', got: {child['name']}"

    # Find the global variable symbol (kind=13 is Variable)
    vars_ = [s for s in symbols if s["kind"] == 13]
    assert len(vars_) >= 1, f"Expected at least one variable symbol, got: {symbols}"

    # Find the 'count' global variable
    count_vars = [v for v in vars_ if v["name"] == "count"]
    assert len(count_vars) >= 1, f"Expected 'count' variable, got: {vars_}"

    print(f"PASS: test_document_symbols ({len(symbols)} symbol(s), {len(funcs)} function(s), {len(vars_)} variable(s))")


def test_document_symbols_empty():
    """documentSymbol returns empty array for invalid SSL."""
    bad_ssl = "this is not valid ssl code;\n"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": "file:///tmp/test_symbols_empty.ssl",
                "languageId": "ssl",
                "version": 1,
                "text": bad_ssl,
            }
        },
    }
    doc_symbol_req = {
        "jsonrpc": "2.0",
        "id": 11,
        "method": "textDocument/documentSymbol",
        "params": {
            "textDocument": {"uri": "file:///tmp/test_symbols_empty.ssl"},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, doc_symbol_req, *shutdown_messages())

    symbol_resp = [r for r in responses if r.get("id") == 11]
    assert len(symbol_resp) == 1, f"Expected documentSymbol response, got: {responses}"
    assert "result" in symbol_resp[0], f"Expected result, got: {symbol_resp[0]}"

    symbols = symbol_resp[0]["result"]
    assert isinstance(symbols, list), f"Expected array result, got: {type(symbols)}"
    assert len(symbols) == 0, f"Expected empty symbols for invalid SSL, got: {symbols}"

    print("PASS: test_document_symbols_empty")


def test_goto_definition_procedure():
    """Go-to-definition on a procedure call jumps to its declaration."""
    # simple.ssl:
    # line 0: variable x;
    # line 2: procedure test begin
    # line 7: procedure start begin
    # line 9:     call test;
    ssl_text = open(os.path.join(os.path.dirname(__file__), "simple.ssl")).read()
    uri = "file:///tmp/test_goto_def.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "test" in "call test;" at line 9, character 9
    definition_req = {
        "jsonrpc": "2.0",
        "id": 20,
        "method": "textDocument/definition",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 9, "character": 9},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, definition_req, *shutdown_messages())

    def_resp = [r for r in responses if r.get("id") == 20]
    assert len(def_resp) == 1, f"Expected definition response, got: {responses}"
    assert "result" in def_resp[0], f"Expected result, got: {def_resp[0]}"

    result = def_resp[0]["result"]
    assert result is not None, "Expected a location, got null"
    assert result["uri"] == uri
    # procedure test is declared at line 2 (0-indexed)
    assert result["range"]["start"]["line"] == 2, f"Expected line 2, got: {result['range']['start']['line']}"

    print("PASS: test_goto_definition_procedure")


def test_goto_definition_variable():
    """Go-to-definition on a variable jumps to its declaration."""
    ssl_text = open(os.path.join(os.path.dirname(__file__), "simple.ssl")).read()
    uri = "file:///tmp/test_goto_def_var.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "x" in "x := 1;" at line 8, character 4
    definition_req = {
        "jsonrpc": "2.0",
        "id": 21,
        "method": "textDocument/definition",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 8, "character": 4},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, definition_req, *shutdown_messages())

    def_resp = [r for r in responses if r.get("id") == 21]
    assert len(def_resp) == 1, f"Expected definition response, got: {responses}"
    assert "result" in def_resp[0], f"Expected result, got: {def_resp[0]}"

    result = def_resp[0]["result"]
    assert result is not None, "Expected a location, got null"
    assert result["uri"] == uri
    # variable x is declared at line 0 (0-indexed)
    assert result["range"]["start"]["line"] == 0, f"Expected line 0, got: {result['range']['start']['line']}"

    print("PASS: test_goto_definition_variable")


def test_find_references_procedure():
    """Find references on a procedure returns call sites (and declaration with includeDeclaration)."""
    ssl_text = open(os.path.join(os.path.dirname(__file__), "simple.ssl")).read()
    uri = "file:///tmp/test_refs_proc.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "test" in "call test;" at line 9, character 9
    refs_req = {
        "jsonrpc": "2.0",
        "id": 30,
        "method": "textDocument/references",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 9, "character": 9},
            "context": {"includeDeclaration": True},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, refs_req, *shutdown_messages())

    refs_resp = [r for r in responses if r.get("id") == 30]
    assert len(refs_resp) == 1, f"Expected references response, got: {responses}"
    assert "result" in refs_resp[0], f"Expected result, got: {refs_resp[0]}"

    result = refs_resp[0]["result"]
    assert isinstance(result, list), f"Expected array result, got: {type(result)}"
    assert len(result) >= 2, f"Expected at least 2 locations (declaration + call site), got: {result}"

    lines = sorted([loc["range"]["start"]["line"] for loc in result])
    # procedure test is declared at line 2, referenced at line 9
    assert 2 in lines, f"Expected declaration at line 2, got lines: {lines}"
    assert 9 in lines, f"Expected reference at line 9, got lines: {lines}"

    # All locations should have the correct URI
    for loc in result:
        assert loc["uri"] == uri, f"Expected uri {uri}, got: {loc['uri']}"

    print(f"PASS: test_find_references_procedure ({len(result)} location(s))")


def test_find_references_variable():
    """Find references on a variable returns usage sites (and declaration with includeDeclaration)."""
    ssl_text = open(os.path.join(os.path.dirname(__file__), "simple.ssl")).read()
    uri = "file:///tmp/test_refs_var.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "x" in "x := 1;" at line 8, character 4
    refs_req = {
        "jsonrpc": "2.0",
        "id": 31,
        "method": "textDocument/references",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 8, "character": 4},
            "context": {"includeDeclaration": True},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, refs_req, *shutdown_messages())

    refs_resp = [r for r in responses if r.get("id") == 31]
    assert len(refs_resp) == 1, f"Expected references response, got: {responses}"
    assert "result" in refs_resp[0], f"Expected result, got: {refs_resp[0]}"

    result = refs_resp[0]["result"]
    assert isinstance(result, list), f"Expected array result, got: {type(result)}"
    assert len(result) >= 2, f"Expected at least 2 locations (declaration + usage), got: {result}"

    lines = sorted([loc["range"]["start"]["line"] for loc in result])
    # variable x is declared at line 0, referenced at line 8
    assert 0 in lines, f"Expected declaration at line 0, got lines: {lines}"
    assert 8 in lines, f"Expected reference at line 8, got lines: {lines}"

    # All locations should have the correct URI
    for loc in result:
        assert loc["uri"] == uri, f"Expected uri {uri}, got: {loc['uri']}"

    print(f"PASS: test_find_references_variable ({len(result)} location(s))")


def test_completion_builtins():
    """Completion returns built-in opcodes matching a prefix."""
    # "rand" on line 3 should match the built-in "random"
    ssl_text = "variable x;\n\nprocedure start begin\n    rand\nend\n"
    uri = "file:///tmp/test_completion_builtins.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor at end of "rand" on line 3, character 8 (4 spaces + 4 chars)
    completion_req = {
        "jsonrpc": "2.0",
        "id": 40,
        "method": "textDocument/completion",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 8},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, completion_req, *shutdown_messages())

    comp_resp = [r for r in responses if r.get("id") == 40]
    assert len(comp_resp) == 1, f"Expected completion response, got: {responses}"
    assert "result" in comp_resp[0], f"Expected result, got: {comp_resp[0]}"

    result = comp_resp[0]["result"]
    assert isinstance(result, list), f"Expected array result, got: {type(result)}"
    assert len(result) > 0, "Expected at least one completion item"

    labels = [item["label"] for item in result]
    assert "random" in labels, f"Expected 'random' in completions, got: {labels}"

    # Verify structure of first item
    random_items = [item for item in result if item["label"] == "random"]
    assert random_items[0]["kind"] == 3, f"Expected Function kind (3), got: {random_items[0]['kind']}"
    assert "detail" in random_items[0], "Expected detail (signature) on builtin completion"

    print(f"PASS: test_completion_builtins ({len(result)} item(s))")


def test_completion_user_symbols():
    """Completion returns user-defined procedures and variables."""
    # Valid SSL — cursor placed mid-word at "my_" in "my_counter" on line 7
    ssl_text = "variable my_counter := 0;\nvariable my_flag := 1;\n\nprocedure my_helper begin\nend\n\nprocedure start begin\n    my_counter := 1;\nend\n"
    uri = "file:///tmp/test_completion_user.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor after "my_" on line 7: 4 spaces + "my_" = character 7
    completion_req = {
        "jsonrpc": "2.0",
        "id": 41,
        "method": "textDocument/completion",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 7, "character": 7},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, completion_req, *shutdown_messages())

    comp_resp = [r for r in responses if r.get("id") == 41]
    assert len(comp_resp) == 1, f"Expected completion response, got: {responses}"

    result = comp_resp[0]["result"]
    assert isinstance(result, list), f"Expected array result, got: {type(result)}"

    labels = [item["label"] for item in result]
    assert "my_counter" in labels, f"Expected 'my_counter' in completions, got: {labels}"
    assert "my_flag" in labels, f"Expected 'my_flag' in completions, got: {labels}"
    assert "my_helper" in labels, f"Expected 'my_helper' in completions, got: {labels}"

    # Check kinds: procedures are Function (3), variables are Variable (6)
    by_label = {item["label"]: item for item in result}
    assert by_label["my_helper"]["kind"] == 3, f"Expected Function kind for procedure, got: {by_label['my_helper']['kind']}"
    assert by_label["my_counter"]["kind"] == 6, f"Expected Variable kind for variable, got: {by_label['my_counter']['kind']}"

    print(f"PASS: test_completion_user_symbols ({len(result)} item(s))")


def test_completion_no_prefix():
    """Completion returns null when cursor is not on an identifier prefix."""
    ssl_text = "variable x;\n\nprocedure start begin\n    \nend\n"
    uri = "file:///tmp/test_completion_empty.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on empty line 3, character 4 (just whitespace)
    completion_req = {
        "jsonrpc": "2.0",
        "id": 42,
        "method": "textDocument/completion",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 4},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, completion_req, *shutdown_messages())

    comp_resp = [r for r in responses if r.get("id") == 42]
    assert len(comp_resp) == 1, f"Expected completion response, got: {responses}"

    result = comp_resp[0]["result"]
    assert result is None, f"Expected null for no prefix, got: {result}"

    print("PASS: test_completion_no_prefix")


def test_signature_help_capability():
    """Initialize response advertises signatureHelpProvider with trigger characters."""
    responses, stderr, code = run_lsp(*init_messages(), *shutdown_messages())

    caps = responses[0]["result"]["capabilities"]
    assert "signatureHelpProvider" in caps, f"Expected signatureHelpProvider, got: {caps}"
    provider = caps["signatureHelpProvider"]
    assert "triggerCharacters" in provider, f"Expected triggerCharacters, got: {provider}"
    triggers = provider["triggerCharacters"]
    assert "(" in triggers, f"Expected '(' in trigger chars, got: {triggers}"
    assert "," in triggers, f"Expected ',' in trigger chars, got: {triggers}"

    print("PASS: test_signature_help_capability")


def test_signature_help_builtin():
    """Signature help shows parameter info for a built-in opcode."""
    # Cursor inside random( on line 3, character 11: "    random(|"
    ssl_text = "variable x;\n\nprocedure start begin\n    random(\nend\n"
    uri = "file:///tmp/test_sighelp_builtin.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    sig_req = {
        "jsonrpc": "2.0",
        "id": 50,
        "method": "textDocument/signatureHelp",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 11},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, sig_req, *shutdown_messages())

    sig_resp = [r for r in responses if r.get("id") == 50]
    assert len(sig_resp) == 1, f"Expected signatureHelp response, got: {responses}"
    assert "result" in sig_resp[0], f"Expected result, got: {sig_resp[0]}"

    result = sig_resp[0]["result"]
    assert result is not None, "Expected SignatureHelp, got null"
    assert "signatures" in result, f"Expected signatures array, got: {result}"
    assert len(result["signatures"]) == 1, f"Expected 1 signature, got: {len(result['signatures'])}"

    sig = result["signatures"][0]
    assert "random" in sig["label"], f"Expected 'random' in label, got: {sig['label']}"
    assert "parameters" in sig, f"Expected parameters, got: {sig}"
    assert len(sig["parameters"]) == 2, f"Expected 2 parameters (min, max), got: {len(sig['parameters'])}"

    # First param active (activeParameter == 0)
    assert result["activeParameter"] == 0, f"Expected activeParameter 0, got: {result['activeParameter']}"

    # Check documentation exists
    assert "documentation" in sig, f"Expected documentation, got: {sig}"

    print(f"PASS: test_signature_help_builtin (label: {sig['label']})")


def test_signature_help_builtin_second_param():
    """Signature help highlights the second parameter after a comma."""
    # "    random(1, " — cursor at character 14
    ssl_text = "variable x;\n\nprocedure start begin\n    random(1, \nend\n"
    uri = "file:///tmp/test_sighelp_second.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    sig_req = {
        "jsonrpc": "2.0",
        "id": 51,
        "method": "textDocument/signatureHelp",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 14},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, sig_req, *shutdown_messages())

    sig_resp = [r for r in responses if r.get("id") == 51]
    result = sig_resp[0]["result"]
    assert result is not None, "Expected SignatureHelp, got null"
    assert result["activeParameter"] == 1, f"Expected activeParameter 1, got: {result['activeParameter']}"

    print("PASS: test_signature_help_builtin_second_param")


def test_signature_help_user_procedure():
    """Signature help shows parameters for a user-defined procedure."""
    # Valid SSL with a two-arg procedure; cursor placed inside the call
    ssl_text = (
        "procedure calculate(variable a, variable b) begin\n"
        "end\n"
        "\n"
        "procedure start begin\n"
        "    call calculate(1, 2);\n"
        "end\n"
    )
    uri = "file:///tmp/test_sighelp_user.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "2" in "calculate(1, 2)" — line 4, character 22 (second param)
    sig_req = {
        "jsonrpc": "2.0",
        "id": 52,
        "method": "textDocument/signatureHelp",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 4, "character": 22},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, sig_req, *shutdown_messages())

    sig_resp = [r for r in responses if r.get("id") == 52]
    assert len(sig_resp) == 1, f"Expected signatureHelp response, got: {responses}"

    result = sig_resp[0]["result"]
    assert result is not None, "Expected SignatureHelp for user procedure, got null"

    sig = result["signatures"][0]
    assert "calculate" in sig["label"], f"Expected 'calculate' in label, got: {sig['label']}"
    assert "parameters" in sig, f"Expected parameters, got: {sig}"
    assert len(sig["parameters"]) == 2, f"Expected 2 parameters, got: {len(sig['parameters'])}"

    # Second param active (after comma)
    assert result["activeParameter"] == 1, f"Expected activeParameter 1, got: {result['activeParameter']}"

    print(f"PASS: test_signature_help_user_procedure (label: {sig['label']})")


def test_signature_help_not_in_call():
    """Signature help returns null when cursor is not inside a function call."""
    ssl_text = "variable x;\n\nprocedure start begin\n    x := 1;\nend\n"
    uri = "file:///tmp/test_sighelp_null.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "x := 1;" — not inside any call parens
    sig_req = {
        "jsonrpc": "2.0",
        "id": 53,
        "method": "textDocument/signatureHelp",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 6},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, sig_req, *shutdown_messages())

    sig_resp = [r for r in responses if r.get("id") == 53]
    assert len(sig_resp) == 1, f"Expected signatureHelp response, got: {responses}"

    result = sig_resp[0]["result"]
    assert result is None, f"Expected null when not in a call, got: {result}"

    print("PASS: test_signature_help_not_in_call")


def test_goto_definition_define():
    """Go-to-definition on a #define macro jumps to its definition line."""
    ssl_text = (
        "#define MAX_HP 100\n"
        "\n"
        "procedure start begin\n"
        "    variable x := MAX_HP;\n"
        "end\n"
    )
    uri = "file:///tmp/test_goto_def_define.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "MAX_HP" in "    variable x := MAX_HP;" at line 3, character 18
    definition_req = {
        "jsonrpc": "2.0",
        "id": 22,
        "method": "textDocument/definition",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 18},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, definition_req, *shutdown_messages())

    def_resp = [r for r in responses if r.get("id") == 22]
    assert len(def_resp) == 1, f"Expected definition response, got: {responses}"
    assert "result" in def_resp[0], f"Expected result, got: {def_resp[0]}"

    result = def_resp[0]["result"]
    assert result is not None, "Expected a location, got null"
    assert result["uri"] == uri
    # #define MAX_HP is at line 0 (0-indexed)
    assert result["range"]["start"]["line"] == 0, f"Expected line 0, got: {result['range']['start']['line']}"

    print("PASS: test_goto_definition_define")


def test_goto_definition_include():
    """Go-to-definition on a #include directive opens the included file."""
    test_dir = os.path.dirname(os.path.abspath(__file__))
    real_path = os.path.join(test_dir, "test_goto_def_include.ssl")
    uri = "file://" + real_path
    ssl_text = '#include "headers/sfall.h"\n\nprocedure start begin\nend\n'

    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on the #include line (line 0, character 10 — on the path)
    definition_req = {
        "jsonrpc": "2.0",
        "id": 24,
        "method": "textDocument/definition",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 0, "character": 10},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, definition_req, *shutdown_messages())

    def_resp = [r for r in responses if r.get("id") == 24]
    assert len(def_resp) == 1, f"Expected definition response, got: {responses}"
    assert "result" in def_resp[0], f"Expected result, got: {def_resp[0]}"

    result = def_resp[0]["result"]
    assert result is not None, "Expected a location for #include, got null"
    assert result["uri"].startswith("file://"), f"Expected file:// URI, got: {result['uri']}"
    assert result["uri"].endswith("headers/sfall.h"), f"Expected URI ending with headers/sfall.h, got: {result['uri']}"
    assert result["range"]["start"]["line"] == 0, f"Expected line 0, got: {result['range']['start']['line']}"

    print(f"PASS: test_goto_definition_include (-> {'/'.join(result['uri'].split('/')[-2:])})")


def test_goto_definition_define_from_header():
    """Go-to-definition on a #define from an included header jumps to the header file."""
    test_dir = os.path.dirname(os.path.abspath(__file__))
    # Use a URI with the real test directory so #include paths resolve
    real_path = os.path.join(test_dir, "test_goto_def_header.ssl")
    uri = "file://" + real_path
    ssl_text = '#include "headers/sfall.h"\n\nprocedure start begin\n    variable x := WORLDMAP;\nend\n'

    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "WORLDMAP" in "    variable x := WORLDMAP;" at line 3, character 18
    definition_req = {
        "jsonrpc": "2.0",
        "id": 23,
        "method": "textDocument/definition",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 18},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, definition_req, *shutdown_messages())

    def_resp = [r for r in responses if r.get("id") == 23]
    assert len(def_resp) == 1, f"Expected definition response, got: {responses}"
    assert "result" in def_resp[0], f"Expected result, got: {def_resp[0]}"

    result = def_resp[0]["result"]
    assert result is not None, "Expected a location for header define, got null"
    # URI should point to sfall.h in the headers directory
    assert result["uri"].endswith("headers/sfall.h"), f"Expected URI ending with headers/sfall.h, got: {result['uri']}"
    assert result["uri"].startswith("file://"), f"Expected file:// URI, got: {result['uri']}"
    assert result["range"]["start"]["line"] >= 0, f"Expected non-negative line, got: {result['range']['start']['line']}"

    print(f"PASS: test_goto_definition_define_from_header (-> {result['uri'].split('/')[-1]}:{result['range']['start']['line']})")


def test_hover_define():
    """Hover on a #define macro shows its definition and source location."""
    ssl_text = (
        "#define MAX_HP 100\n"
        "\n"
        "procedure start begin\n"
        "    variable x := MAX_HP;\n"
        "end\n"
    )
    uri = "file:///tmp/test_hover_define.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "MAX_HP" in "    variable x := MAX_HP;" at line 3, character 18
    hover_req = {
        "jsonrpc": "2.0",
        "id": 60,
        "method": "textDocument/hover",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 18},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, hover_req, *shutdown_messages())

    hover_resp = [r for r in responses if r.get("id") == 60]
    assert len(hover_resp) == 1, f"Expected hover response, got: {responses}"
    assert "result" in hover_resp[0], f"Expected result, got: {hover_resp[0]}"

    result = hover_resp[0]["result"]
    assert result is not None, "Expected hover result, got null"
    assert "contents" in result, f"Expected contents, got: {result}"

    contents = result["contents"]["value"]
    assert "#define MAX_HP 100" in contents, f"Expected '#define MAX_HP 100' in hover, got: {contents}"
    assert "current file" in contents, f"Expected 'current file' in hover, got: {contents}"

    print("PASS: test_hover_define")


def test_hover_builtin():
    """Hover on a built-in opcode shows its signature."""
    ssl_text = (
        "variable x;\n"
        "\n"
        "procedure start begin\n"
        "    x := random(0, 10);\n"
        "end\n"
    )
    uri = "file:///tmp/test_hover_builtin.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "random" in "    x := random(0, 10);" at line 3, character 9
    hover_req = {
        "jsonrpc": "2.0",
        "id": 61,
        "method": "textDocument/hover",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 9},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, hover_req, *shutdown_messages())

    hover_resp = [r for r in responses if r.get("id") == 61]
    assert len(hover_resp) == 1, f"Expected hover response, got: {responses}"
    assert "result" in hover_resp[0], f"Expected result, got: {hover_resp[0]}"

    result = hover_resp[0]["result"]
    assert result is not None, "Expected hover result, got null"
    assert "contents" in result, f"Expected contents, got: {result}"

    contents = result["contents"]["value"]
    assert "random" in contents, f"Expected 'random' in hover, got: {contents}"

    print("PASS: test_hover_builtin")


def test_completion_defines():
    """Completion returns #define macros matching a prefix."""
    ssl_text = (
        "#define MAX_HP 100\n"
        "#define MAX_MP 50\n"
        "\n"
        "procedure start begin\n"
        "    variable x := MAX\n"
        "end\n"
    )
    uri = "file:///tmp/test_completion_defines.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor after "MAX" on line 4: "    variable x := MAX" → character 22
    completion_req = {
        "jsonrpc": "2.0",
        "id": 43,
        "method": "textDocument/completion",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 4, "character": 22},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, completion_req, *shutdown_messages())

    comp_resp = [r for r in responses if r.get("id") == 43]
    assert len(comp_resp) == 1, f"Expected completion response, got: {responses}"
    assert "result" in comp_resp[0], f"Expected result, got: {comp_resp[0]}"

    result = comp_resp[0]["result"]
    assert isinstance(result, list), f"Expected array result, got: {type(result)}"

    labels = [item["label"] for item in result]
    assert "MAX_HP" in labels, f"Expected 'MAX_HP' in completions, got: {labels}"
    assert "MAX_MP" in labels, f"Expected 'MAX_MP' in completions, got: {labels}"

    by_label = {item["label"]: item for item in result}
    # Object-like defines should have kind Constant (21)
    assert by_label["MAX_HP"]["kind"] == 21, f"Expected Constant kind (21), got: {by_label['MAX_HP']['kind']}"
    assert "#define" in by_label["MAX_HP"]["detail"], f"Expected '#define' in detail, got: {by_label['MAX_HP']['detail']}"

    print(f"PASS: test_completion_defines ({len(result)} item(s))")


def test_completion_define_function_like():
    """Completion returns function-like #define macros with correct kind."""
    ssl_text = (
        "#define CALC(x, y) ((x) + (y))\n"
        "\n"
        "procedure start begin\n"
        "    variable z := CAL\n"
        "end\n"
    )
    uri = "file:///tmp/test_completion_define_func.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor after "CAL" on line 3: "    variable z := CAL" → character 22
    completion_req = {
        "jsonrpc": "2.0",
        "id": 44,
        "method": "textDocument/completion",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 22},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, completion_req, *shutdown_messages())

    comp_resp = [r for r in responses if r.get("id") == 44]
    assert len(comp_resp) == 1, f"Expected completion response, got: {responses}"
    assert "result" in comp_resp[0], f"Expected result, got: {comp_resp[0]}"

    result = comp_resp[0]["result"]
    assert isinstance(result, list), f"Expected array result, got: {type(result)}"

    labels = [item["label"] for item in result]
    assert "CALC" in labels, f"Expected 'CALC' in completions, got: {labels}"

    by_label = {item["label"]: item for item in result}
    # Function-like defines should have kind Function (3)
    assert by_label["CALC"]["kind"] == 3, f"Expected Function kind (3), got: {by_label['CALC']['kind']}"
    assert "#define CALC(x, y)" in by_label["CALC"]["detail"], f"Expected '#define CALC(x, y)' in detail, got: {by_label['CALC']['detail']}"

    print(f"PASS: test_completion_define_function_like ({len(result)} item(s))")


def test_find_references_define():
    """Find references on a #define macro returns its usages in the current file."""
    ssl_text = (
        "#define MAX_HP 100\n"
        "\n"
        "procedure start begin\n"
        "    variable x := MAX_HP;\n"
        "    variable y := MAX_HP;\n"
        "end\n"
    )
    uri = "file:///tmp/test_refs_define.ssl"
    did_open = {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": uri,
                "languageId": "ssl",
                "version": 1,
                "text": ssl_text,
            }
        },
    }
    # Cursor on "MAX_HP" at line 3, character 18
    refs_req = {
        "jsonrpc": "2.0",
        "id": 32,
        "method": "textDocument/references",
        "params": {
            "textDocument": {"uri": uri},
            "position": {"line": 3, "character": 18},
            "context": {"includeDeclaration": True},
        },
    }

    responses, stderr, code = run_lsp(*init_messages(), did_open, refs_req, *shutdown_messages())

    refs_resp = [r for r in responses if r.get("id") == 32]
    assert len(refs_resp) == 1, f"Expected references response, got: {responses}"
    assert "result" in refs_resp[0], f"Expected result, got: {refs_resp[0]}"

    result = refs_resp[0]["result"]
    assert isinstance(result, list), f"Expected array result, got: {type(result)}"
    # Declaration at line 0 + usages at lines 3 and 4 = 3 locations
    assert len(result) == 3, f"Expected 3 locations (declaration + 2 usages), got {len(result)}: {result}"

    lines = sorted([loc["range"]["start"]["line"] for loc in result])
    assert 0 in lines, f"Expected declaration at line 0, got lines: {lines}"
    assert 3 in lines, f"Expected reference at line 3, got lines: {lines}"
    assert 4 in lines, f"Expected reference at line 4, got lines: {lines}"

    # Usage locations should have correct character offsets
    usage_locs = [loc for loc in result if loc["range"]["start"]["line"] in (3, 4)]
    for loc in usage_locs:
        assert loc["range"]["start"]["character"] == 18, f"Expected character 18, got: {loc['range']['start']['character']}"
        assert loc["range"]["end"]["character"] == 24, f"Expected end character 24, got: {loc['range']['end']['character']}"

    # All locations should have the correct URI
    for loc in result:
        assert loc["uri"] == uri, f"Expected uri {uri}, got: {loc['uri']}"

    print(f"PASS: test_find_references_define ({len(result)} location(s))")


if __name__ == "__main__":
    tests = [
        test_initialize,
        test_diagnostics_on_bad_ssl,
        test_diagnostics_on_valid_ssl,
        test_did_change_updates_diagnostics,
        test_shutdown_response,
        test_unknown_method,
        test_document_symbols,
        test_document_symbols_empty,
        test_goto_definition_procedure,
        test_goto_definition_variable,
        test_goto_definition_define,
        test_goto_definition_include,
        test_goto_definition_define_from_header,
        test_find_references_procedure,
        test_find_references_variable,
        test_find_references_define,
        test_hover_define,
        test_hover_builtin,
        test_completion_defines,
        test_completion_define_function_like,
        test_completion_builtins,
        test_completion_user_symbols,
        test_completion_no_prefix,
        test_signature_help_capability,
        test_signature_help_builtin,
        test_signature_help_builtin_second_param,
        test_signature_help_user_procedure,
        test_signature_help_not_in_call,
    ]

    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            passed += 1
        except Exception as e:
            print(f"FAIL: {test.__name__}: {e}")
            failed += 1

    print(f"\n{passed}/{passed + failed} tests passed")
    sys.exit(1 if failed > 0 else 0)
