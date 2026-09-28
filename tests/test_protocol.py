from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from mcp_for_godot.server import (  # noqa: E402
    GodotMCP,
    MODERN_PROTOCOL_VERSION,
    PROTOCOL_VERSION,
    SERVER_VERSION,
    TOOLS,
    _visible_tools,
    handle_message,
)


class ProtocolContract(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="mcp-for-godot-protocol-")
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name)
        (self.project / "project.godot").write_text("config_version=5\n", encoding="utf-8")

    def server(self, *flags: bool) -> GodotMCP:
        values = list(flags) + [False] * (6 - len(flags))
        return GodotMCP(self.project, Path(sys.executable), *values[:6])

    @staticmethod
    def modern(**values: object) -> dict:
        return {
            **values,
            "_meta": {
                "io.modelcontextprotocol/protocolVersion": MODERN_PROTOCOL_VERSION,
                "io.modelcontextprotocol/clientInfo": {"name": "contract", "version": "1"},
                "io.modelcontextprotocol/clientCapabilities": {},
            },
        }

    def test_release_and_permission_profile_counts(self) -> None:
        self.assertEqual(SERVER_VERSION, "0.10.0")
        self.assertEqual(len(TOOLS), 65)
        cases = {
            (False, False): 20,
            (False, True): 27,
            (True, False): 40,
            (True, True): 50,
            (True, True, True, True, True, False): 58,
            (True, True, True, True, True, True): 65,
        }
        for flags, count in cases.items():
            with self.subTest(flags=flags):
                self.assertEqual(len(_visible_tools(self.server(*flags))), count)

    def test_legacy_initialize_list_and_read(self) -> None:
        server = self.server()
        before = handle_message(server, {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}})
        self.assertEqual(before["error"]["code"], -32602)
        initialized = handle_message(server, {"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"clientInfo": {"name": "test", "version": "1"}}})
        self.assertEqual(initialized["result"]["protocolVersion"], PROTOCOL_VERSION)
        listed = handle_message(server, {"jsonrpc": "2.0", "id": 3, "method": "tools/list", "params": {}})
        self.assertEqual(len(listed["result"]["tools"]), 20)
        called = handle_message(server, {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "godot_list_files", "arguments": {}}})
        self.assertFalse(called["result"]["isError"])

    def test_modern_discovery_and_version_rejection(self) -> None:
        server = self.server()
        discovered = handle_message(server, {"jsonrpc": "2.0", "id": 1, "method": "server/discover", "params": self.modern()})
        self.assertEqual(discovered["result"]["resultType"], "complete")
        self.assertIn(MODERN_PROTOCOL_VERSION, discovered["result"]["supportedVersions"])
        wrong = self.modern()
        wrong["_meta"]["io.modelcontextprotocol/protocolVersion"] = "1900-01-01"
        rejected = handle_message(server, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": wrong})
        self.assertEqual(rejected["error"]["code"], -32022)

    def test_write_tool_is_not_discoverable_by_default(self) -> None:
        server = self.server()
        listed = handle_message(server, {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": self.modern()})
        names = {tool["name"] for tool in listed["result"]["tools"]}
        self.assertNotIn("godot_add_node_checked", names)
        attempted = handle_message(server, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": self.modern(name="godot_add_node_checked", arguments={})})
        self.assertTrue(attempted["result"]["isError"])
        self.assertEqual(attempted["result"]["structuredContent"]["error"]["code"], "write_disabled")

    def test_real_stdio_keeps_stdout_as_json(self) -> None:
        request = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}) + "\n"
        completed = subprocess.run(
            [sys.executable, "-m", "mcp_for_godot", "--project", str(self.project), "--godot", sys.executable],
            input=request,
            capture_output=True,
            text=True,
            timeout=15,
            env={**__import__("os").environ, "PYTHONPATH": str(ROOT / "src")},
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        reply = json.loads(completed.stdout.strip())
        self.assertEqual(reply["result"]["serverInfo"]["version"], SERVER_VERSION)


if __name__ == "__main__":
    unittest.main()
