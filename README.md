# MCP for Godot

[![CI](https://github.com/Dev-Encrypted/mcp-for-godot/actions/workflows/ci.yml/badge.svg)](https://github.com/Dev-Encrypted/mcp-for-godot/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Dev-Encrypted/mcp-for-godot?include_prereleases)](https://github.com/Dev-Encrypted/mcp-for-godot/releases)
[![License](https://img.shields.io/github/license/Dev-Encrypted/mcp-for-godot)](LICENSE)

[Português do Brasil](README.pt-BR.md) · [Architecture](docs/ARCHITECTURE.md) · [Security](docs/SECURITY-MODEL.md) · [Tool catalog](docs/TOOLS.md)

MCP for Godot is a local bridge that lets MCP-compatible AI clients inspect,
run, observe, and carefully modify one Godot project. It combines a Python
stdio MCP server with an opt-in Godot editor addon.

The design starts read-only. Additional capabilities are exposed only through
explicit command-line flags. Mutating tools use typed inputs, project-scoped
paths, expected hashes or scene revisions, bounded payloads, audit records, and
rollback where the operation can provide it.

> **Preview:** version 0.10.0 exposes 65 tools in the complete profile and 20
> tools in the default read-only profile. Some protected editor operations need
> optional native hooks that are not included in this public repository. The
> server reports those capabilities instead of silently claiming support.

## What it can do

- Inspect project files, editor state, open scenes, scene trees, nodes, graphics
  resources, dependencies, import metadata, and recent process output.
- Observe an opted-in running 2D scene through bounded live snapshots, a frame
  timeline, performance counters, viewport metadata, and on-demand PNG capture.
- Start and stop a managed editor or game process and run headless validation.
- Preview and apply guarded scene, resource, texture-import, and GDScript
  changes when the corresponding permissions are enabled.
- Record summarized operations without storing bridge tokens or script bodies.
- Serve both legacy MCP `2025-11-25` initialization and request-scoped
  `2026-07-28` discovery.

## Trust model in one minute

1. One MCP process controls one explicit project directory.
2. The addon listens on `127.0.0.1` and creates a random session token under
   `.godot/ai_mcp/bridge.json`.
3. Read-only tools are the default. Flags add narrowly defined capabilities.
4. Paths are restricted to `res://`; traversal, links, hidden targets, oversized
   messages, and unsupported file types are rejected.
5. This is a local trusted-workstation boundary. Another process running as the
   same user and able to read the project may also read the bridge token.

Read [the full security model](docs/SECURITY-MODEL.md) before enabling writes,
script changes, input injection, or image capture.

## Requirements

- Python 3.11 or newer
- Godot 4.7.2 for the tested compatibility target
- An MCP client that can launch a local stdio server

## Quick start

Clone and install the Python server:

```bash
git clone https://github.com/Dev-Encrypted/mcp-for-godot.git
cd mcp-for-godot
python -m venv .venv
python -m pip install -e .
```

Install the addon into a Godot project:

```powershell
.\scripts\install-addon.ps1 -Project "C:\path\to\my-game"
```

Or on macOS/Linux:

```bash
./scripts/install-addon.sh /path/to/my-game
```

In Godot, enable **MCP for Godot** in **Project > Project Settings >
Plugins** and keep that editor open. Then configure your client from the
templates in [`clients/`](clients/README.md).

Run the server directly to verify its CLI:

```bash
mcp-for-godot --project /path/to/my-game --godot /path/to/godot
```

The command communicates over stdio, so normal diagnostics go to stderr.

## Permission profiles

| Profile | Flags | Visible tools | Intended use |
|---|---|---:|---|
| Read only | none | 20 | Discovery, scene inspection, live metadata |
| Validation | `--allow-run` | 27 | Headless checks and managed processes |
| Guarded editing | `--allow-write --allow-run` | 50 | Checked edits and transactional workflows |
| Full protected | add `--allow-capture --allow-input --allow-script-write` | 58 | Visual evidence, bounded input, script transactions |
| Legacy compatibility | add `--allow-legacy-write` | 65 | Disposable projects and migration only |

Counts are contractual tests for v0.10.0. A tool can still report a structured
`unavailable` result when the editor, live game, renderer, or native hook it
depends on is absent.

## Live observation is opt-in

Installing the addon does not instrument every game scene. To expose runtime
data, attach `res://addons/mcp_for_godot/runtime_probe.gd` to one node in the
scene, preferably named `AIMonitor`, and run the scene through an editor with
the debugger connected. The sample project shows the expected setup.

The collector limits tree size, viewport count, payload size, text fields, and
sample frequency. Pixel capture requires `--allow-capture` and is performed on
demand. See [live telemetry](docs/LIVE-TELEMETRY.md).

## Stock Godot and optional native hooks

The public package works with stock Godot for project inspection, the local
bridge, live opt-in observation, process lifecycle, and supported public editor
APIs. Native shader parsing, protected scene history, and native debugger event
buffers report unavailable when the editor lacks the corresponding optional C++
hooks. See the exact matrix in [compatibility](docs/COMPATIBILITY.md).

## Tests

```bash
python -m unittest discover -s tests -v
```

To include the real-editor addon parse smoke test:

```powershell
$env:GODOT_BIN = "C:\path\to\Godot_v4.7.2-stable_win64_console.exe"
python -m unittest discover -s tests -v
```

The suite covers protocol negotiation, capability filtering, path confinement,
transaction preview/apply/rollback behavior, addon packaging, and optional
headless editor loading. GPU rendering, driver behavior, and visual correctness
still require hardware-specific validation; a headless pass is not treated as
proof of those properties.

## Project status

This repository contains the MCP server and editor addon. Optional native hooks
are outside this distribution. Planned work is tracked in
[ROADMAP.md](docs/ROADMAP.md), with objective gates for broader backend and
AI-client compatibility.

## License

Original code in this repository is released under the [Apache License 2.0](LICENSE).
Godot attribution and trademark information are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
