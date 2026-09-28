#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 PROJECT_PATH [--force]" >&2
  exit 2
fi

project_root="$(cd "$1" 2>/dev/null && pwd)" || {
  echo "project directory does not exist: $1" >&2
  exit 2
}
[[ -f "$project_root/project.godot" ]] || {
  echo "target does not contain project.godot: $project_root" >&2
  exit 2
}

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd "$script_root/../addons/mcp_for_godot" && pwd)"
addons_root="$project_root/addons"
target="$addons_root/mcp_for_godot"

if [[ -e "$target" ]]; then
  [[ "${2:-}" == "--force" ]] || {
    echo "addon already exists at $target; re-run with --force" >&2
    exit 2
  }
  case "$target" in
    "$addons_root"/*) rm -rf -- "$target" ;;
    *) echo "refusing to remove a path outside the project addons directory" >&2; exit 2 ;;
  esac
fi

mkdir -p -- "$addons_root"
cp -R -- "$source_dir" "$target"
echo "Installed MCP for Godot at $target"
echo "Enable it in Project > Project Settings > Plugins."
