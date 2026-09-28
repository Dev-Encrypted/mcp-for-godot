# Compatibility

## Release target

Version 0.10.0 is developed against Godot 4.7.2. Earlier or later Godot versions
may change editor-only APIs and debugger behavior. They are unsupported until a
matching validation record is added.

## Capability matrix

| Capability | Stock Godot 4.7.2 | Custom native build | Notes |
|---|---:|---:|---|
| Project file inspection | Yes | Yes | No editor required |
| Local editor bridge | Yes | Yes | Addon must be enabled |
| Edited scene inspection | Yes | Yes | Reflects editor state |
| Opt-in runtime 2D samples | Yes | Yes | Scene must contain the probe |
| Timeline and public monitors | Yes | Yes | Scope is reported per value |
| On-demand viewport PNG | Yes | Yes | Requires capture permission |
| Managed editor/game process | Yes | Yes | Only processes owned by server |
| Headless project validation | Yes | Yes | Executes project-controlled code |
| File/resource checkpoints | Yes | Yes | Server-side feature |
| Native shader source validation | No | Yes | Stock build reports unavailable |
| Protected per-scene undo/redo hooks | No | Yes | Required for selected checked edits |
| Native debugger event buffer | No | Yes | Stock build reports unavailable |
| Renderer pass tracing | No | No | Planned; never advertised as present |

"Yes" means the code path is available, not that every renderer, driver, GPU,
or project has been validated.

## MCP clients

The server is stdio-based and does not depend on a vendor SDK. Templates are
provided for Codex and Claude Code. A client's ability to list tools proves
transport and discovery only. Full compatibility also requires real tasks that
exercise permissions, image content, failures, recovery, and correct project
results under the client's current version and model.

## Platforms and renderers

The Python contract tests run on Windows and Linux in CI. The addon parse test
runs when a local `GODOT_BIN` is supplied. Rendering support must be verified
separately for:

- Windows, Linux, and macOS
- Forward+, Mobile, and Compatibility renderers
- Vulkan, Direct3D 12, Metal, and OpenGL paths applicable to the platform
- At least one integrated and one discrete GPU family

Record GPU, driver, operating system, renderer, resolution, scene, warm-up,
sample duration, raw counters, and failures. Do not infer one backend from
another.
