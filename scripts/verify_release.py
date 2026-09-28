"""Fail when the public tree contains packaging drift or common local secrets."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from mcp_for_godot import server  # noqa: E402

TEXT_SUFFIXES = {".cfg", ".gd", ".json", ".md", ".ps1", ".py", ".sh", ".toml", ".tscn", ".txt", ""}
SKIP_PARTS = {".git", ".godot", ".venv", "__pycache__", "build", "dist"}


def public_files() -> list[Path]:
    return [
        path for path in ROOT.rglob("*")
        if path.is_file() and not any(part in SKIP_PARTS for part in path.relative_to(ROOT).parts)
    ]


def main() -> None:
    errors: list[str] = []
    files = public_files()
    forbidden = ["Projetos" + "\\Godot", "Users" + "\\Encry", "bridge.json\"" + ":"]
    token_pattern = re.compile(r"(?:gh[opusr]|github_pat)_[A-Za-z0-9_]{20,}")
    retired_brand_pattern = re.compile("motor" + r"[-_ ]?ia", re.IGNORECASE)
    for path in files:
        relative = path.relative_to(ROOT).as_posix()
        if path.stat().st_size > 1_500_000:
            errors.append(f"oversized publishable file: {relative}")
        if path.suffix.lower() not in TEXT_SUFFIXES and path.name not in {"LICENSE"}:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            errors.append(f"unexpected binary file: {relative}")
            continue
        for marker in forbidden:
            if marker.lower() in text.lower():
                errors.append(f"private marker {marker!r}: {relative}")
        if token_pattern.search(text):
            errors.append(f"credential-shaped token: {relative}")
        if retired_brand_pattern.search(text):
            errors.append(f"retired branding: {relative}")

    if len(server.TOOLS) != 65:
        errors.append(f"tool count drift: {len(server.TOOLS)} != 65")
    required_addon = {"plugin.cfg", "plugin.gd", "live_debugger.gd", "runtime_probe.gd"}
    addon_names = {path.name for path in (ROOT / "addons" / "mcp_for_godot").iterdir() if path.is_file()}
    if not required_addon.issubset(addon_names):
        errors.append(f"addon files missing: {sorted(required_addon - addon_names)}")
    if 'version="0.10.0"' not in (ROOT / "addons" / "mcp_for_godot" / "plugin.cfg").read_text(encoding="utf-8"):
        errors.append("addon version differs from release")

    metadata = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    if metadata["project"]["version"] != server.SERVER_VERSION:
        errors.append("pyproject and server versions differ")
    for config in (ROOT / "clients").glob("*.json"):
        json.loads(config.read_text(encoding="utf-8"))
    for config in (ROOT / "clients").glob("*.toml"):
        tomllib.loads(config.read_text(encoding="utf-8"))

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
    print(json.dumps({"status": "ok", "version": server.SERVER_VERSION, "tools": len(server.TOOLS), "files": len(files)}))


if __name__ == "__main__":
    main()
