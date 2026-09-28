# Minimal live scene

This project demonstrates the opt-in runtime probe. Install the addon into this
directory before opening it:

```powershell
..\..\scripts\install-addon.ps1 -Project .
```

Enable the addon in Godot, open `scenes/main.tscn`, and run the scene from the
editor. Start the MCP server with this directory as `--project`, then call
`godot_status`, `godot_scene_tree`, `godot_live_snapshot`, and
`godot_live_timeline`. Start the server with `--allow-capture` to call
`godot_live_image`.

The scene is intentionally small enough to compare its runtime tree, viewport,
renderer metadata, and monitor values with the editor debugger.
