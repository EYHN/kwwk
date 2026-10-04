import Foundation

/// A tiny MCP server in Python used by the stdio end-to-end tests.
enum FakeMCPServer {
    static let script = #"""
import json, os, sys, threading, time

lock = threading.Lock()
state = {"extra": False, "cancelled": [], "replies": {}}

def send(msg):
    with lock:
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()

def tools():
    page1 = [
        {"name": "echo", "description": "Echo the text back", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
        {"name": "add", "title": "Add numbers", "inputSchema": {"properties": {"a": {"type": "number"}, "b": {"type": "number"}}}},
    ]
    page2 = [
        {"name": "fail", "description": "Always fails", "inputSchema": {"type": "object"}},
        {"name": "slow", "description": "Sleeps", "inputSchema": {"type": "object"}},
        {"name": "image", "description": "Returns an image", "inputSchema": {"type": "object"}},
        {"name": "state", "description": "Internal state", "inputSchema": {"type": "object"}},
        {"name": "change", "description": "Adds a tool", "inputSchema": {"type": "object"}},
        {"name": "env", "description": "Env and cwd", "inputSchema": {"type": "object"}},
        {"name": "exit", "description": "Exits the server", "inputSchema": {"type": "object"}},
    ]
    if state["extra"]:
        page2.append({"name": "late", "description": "Added later", "inputSchema": {"type": "object"}})
    return page1, page2

def text(t):
    return {"content": [{"type": "text", "text": t}]}

def call(mid, params):
    name = params.get("name")
    args = params.get("arguments") or {}
    if name == "echo":
        result = text(args.get("text", ""))
    elif name == "add":
        result = {"content": [], "structuredContent": {"sum": args.get("a", 0) + args.get("b", 0)}}
    elif name == "fail":
        result = {"content": [{"type": "text", "text": "it broke"}], "isError": True}
    elif name == "slow":
        token = (params.get("_meta") or {}).get("progressToken")
        if token is not None:
            send({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": token, "progress": 1, "total": 2, "message": "halfway"}})
        for _ in range(100):
            time.sleep(0.05)
            if mid in state["cancelled"]:
                return
        result = text("done")
    elif name == "image":
        result = {"content": [{"type": "image", "data": "aGVsbG8=", "mimeType": "image/png"},
                              {"type": "resource_link", "uri": "file:///x.txt", "name": "x.txt", "mimeType": "text/plain"},
                              {"type": "resource", "resource": {"uri": "file:///y.txt", "text": "embedded"}}]}
    elif name == "state":
        result = text(json.dumps({"cancelled": state["cancelled"], "replies": state["replies"]}))
    elif name == "change":
        state["extra"] = True
        send({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"})
        result = text("changed")
    elif name == "env":
        result = text(json.dumps({"var": os.environ.get("MCP_TEST_VAR"), "cwd": os.getcwd()}))
    elif name == "exit":
        sys.stderr.write("fake server exiting on request\n")
        sys.stderr.flush()
        os._exit(3)
    else:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "unknown tool " + str(name)}})
        return
    send({"jsonrpc": "2.0", "id": mid, "result": result})

sys.stderr.write("fake server starting\n")
sys.stderr.flush()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    msg = json.loads(line)
    method = msg.get("method")
    mid = msg.get("id")
    if method is None:
        state["replies"][str(mid)] = msg
        continue
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": msg["params"]["protocolVersion"],
            "capabilities": {"tools": {"listChanged": True}},
            "serverInfo": {"name": "fake", "version": "1.2.3"},
            "instructions": "Fake server for tests.\nSecond line."}})
    elif method == "notifications/initialized":
        send({"jsonrpc": "2.0", "id": "s1", "method": "ping"})
        send({"jsonrpc": "2.0", "id": "s2", "method": "sampling/createMessage", "params": {}})
    elif method == "notifications/cancelled":
        state["cancelled"].append(msg["params"]["requestId"])
    elif method == "tools/list":
        page1, page2 = tools()
        cursor = (msg.get("params") or {}).get("cursor")
        if cursor is None:
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": page1, "nextCursor": "page2"}})
        else:
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": page2}})
    elif method == "tools/call":
        threading.Thread(target=call, args=(mid, msg.get("params") or {}), daemon=True).start()
    elif method == "ping":
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
"""#

    /// Write the script into a fresh temp directory and return its path.
    static func install() throws -> (script: String, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kwwk-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("server.py")
        try script.write(to: url, atomically: true, encoding: .utf8)
        return (url.path, directory)
    }

    static var python: String? {
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}
