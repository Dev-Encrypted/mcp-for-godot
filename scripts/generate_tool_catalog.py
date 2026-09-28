"""Generate docs/TOOLS.md from the server's canonical tool definitions."""

from __future__ import annotations

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from mcp_for_godot import server  # noqa: E402


def gates(name: str) -> str:
    required: list[str] = []
    if name in server.WRITE_TOOLS:
        required.append("`--allow-write`")
    if name in server.RUN_TOOLS or name in {"godot_script_apply", "godot_mesh_library_export"}:
        required.append("`--allow-run`")
    if name in {"godot_live_image", "godot_live_evidence", "godot_graphics_compare"}:
        required.append("`--allow-capture`")
    if name == "godot_input_action":
        required.append("`--allow-input`")
    if name in {"godot_script_preview", "godot_script_apply", "godot_script_rollback", "godot_gameplay_attach_script_checked"}:
        required.append("`--allow-script-write`")
    if name in server.LEGACY_WRITE_TOOLS:
        required.append("`--allow-legacy-write`")
    return ", ".join(dict.fromkeys(required)) or "Read-only baseline"


def main() -> None:
    lines = [
        "# Tool catalog",
        "",
        f"Generated from `mcp_for_godot.server` version {server.SERVER_VERSION}. Do not edit by hand.",
        "",
        f"Total: **{len(server.TOOLS)} tools**.",
        "",
        "| Tool | Visibility gate | Canonical summary |",
        "|---|---|---|",
    ]
    for tool in sorted(server.TOOLS, key=lambda item: item["name"]):
        description = tool["description"].replace("|", "\\|").replace("\n", " ")
        lines.append(f"| `{tool['name']}` | {gates(tool['name'])} | {description} |")
    lines.extend([
        "",
        "A visible tool may still return `unavailable` when its editor, runtime,",
        "renderer, or native-hook dependency is absent. Visibility is permission",
        "filtering, not a claim that the current environment can complete the call.",
        "",
    ])
    (ROOT / "docs" / "TOOLS.md").write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
