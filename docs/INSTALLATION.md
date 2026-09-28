# Installation

## 1. Install the Python server

Python 3.11 or newer is required.

```bash
git clone https://github.com/Dev-Encrypted/mcp-for-godot.git
cd mcp-for-godot
python -m venv .venv
python -m pip install -e .
```

On Windows, use `.venv\Scripts\python`; on macOS/Linux use `.venv/bin/python`.
The installed commands are `mcp-for-godot` and `mcp-for-godot-capture`.

## 2. Install the Godot addon

```powershell
.\scripts\install-addon.ps1 -Project "C:\games\my-project"
```

```bash
./scripts/install-addon.sh /home/me/games/my-project
```

The target must already contain `project.godot`. The installer refuses to
replace an existing addon unless `-Force` or `--force` is supplied.

Enable **MCP for Godot** under **Project > Project Settings > Plugins**.
The editor creates `.godot/ai_mcp/bridge.json` when the addon starts.

## 3. Configure an MCP client

Copy a template from [`clients/`](../clients/README.md), replace the Python,
project, and Godot paths, and restart the client. Keep arguments as separate
array items; do not combine paths with flags into one shell string.

Use the read-only template first. Add flags after reviewing the
[security model](SECURITY-MODEL.md).

## 4. Enable live scene telemetry when needed

Add a plain `Node` called `AIMonitor` to the specific scene and attach:

```text
res://addons/mcp_for_godot/runtime_probe.gd
```

Run the scene from the editor so its debugger channel is connected. The probe
does not run in scenes where it was not explicitly attached.

## 5. Verify

Ask the client to call `godot_capabilities`, `godot_status`, and
`godot_scene_tree`. With a probe-enabled running scene, call
`godot_live_snapshot` and compare the returned scene path and performance
monitors with the editor debugger.

Common failures:

| Code or symptom | Resolution |
|---|---|
| `bridge_unavailable` | Enable the addon and open the same project in Godot |
| project mismatch | Check the exact `--project` path and close duplicate editors |
| `write_disabled`, `run_disabled`, or similar | Restart the MCP server with only the required flag |
| `unavailable` for live data | Run a probe-enabled scene through the editor debugger |
| safe history unavailable | Use a compatible custom build or avoid that checked mutation |
| client shows no tools | Verify its stdio command and inspect stderr, never stdout |
