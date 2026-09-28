from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PackagingContract(unittest.TestCase):
    def test_addon_has_expected_entry_points(self) -> None:
        addon = ROOT / "addons" / "mcp_for_godot"
        names = {path.name for path in addon.iterdir() if path.is_file()}
        self.assertTrue({"plugin.cfg", "plugin.gd", "runtime_probe.gd", "live_debugger.gd"}.issubset(names))
        self.assertEqual(len(names), 15)
        self.assertIn('version="0.10.0"', (addon / "plugin.cfg").read_text(encoding="utf-8"))

    def test_client_json_is_valid_and_has_no_permissions_by_default(self) -> None:
        config = json.loads((ROOT / "clients" / "claude-code.readonly.json").read_text(encoding="utf-8"))
        args = config["mcpServers"]["godot-project"]["args"]
        self.assertNotIn("--allow-write", args)
        self.assertNotIn("--allow-run", args)

    def test_real_editor_loads_addon_when_requested(self) -> None:
        executable = os.environ.get("GODOT_BIN")
        if not executable:
            self.skipTest("GODOT_BIN is not set")
        godot = Path(executable)
        if not godot.is_file():
            self.fail(f"GODOT_BIN does not exist: {godot}")
        with tempfile.TemporaryDirectory(prefix="mcp-for-godot-") as raw:
            project = Path(raw)
            shutil.copytree(ROOT / "addons" / "mcp_for_godot", project / "addons" / "mcp_for_godot")
            (project / "project.godot").write_text(
                'config_version=5\n[application]\nconfig/name="MCP for Godot addon parse"\n'
                '[editor_plugins]\nenabled=PackedStringArray("res://addons/mcp_for_godot/plugin.cfg")\n',
                encoding="utf-8",
            )
            environment = os.environ.copy()
            isolated_profile = project / ".profile"
            isolated_profile.mkdir()
            environment.update({"APPDATA": str(isolated_profile), "LOCALAPPDATA": str(isolated_profile), "USERPROFILE": str(isolated_profile), "HOME": str(isolated_profile)})
            completed = subprocess.run(
                [str(godot), "--headless", "--editor", "--path", str(project), "--quit"],
                cwd=project,
                capture_output=True,
                text=True,
                timeout=60,
                env=environment,
            )
            output = completed.stdout + completed.stderr
            self.assertEqual(completed.returncode, 0, output[-5000:])
            self.assertIn("MCP for Godot: ponte local ativa", output)
            self.assertNotIn("PARSE ERROR", output.upper())


if __name__ == "__main__":
    unittest.main()
