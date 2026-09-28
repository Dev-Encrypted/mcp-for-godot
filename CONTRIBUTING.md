# Contributing

Thank you for helping improve MCP for Godot.

## Before opening a change

1. Create an issue for protocol, permission, or compatibility changes.
2. Keep every tool project-scoped and typed. Do not add arbitrary shell,
   expression-evaluation, or unrestricted file-system operations.
3. Add explicit bounds, preconditions, structured errors, and rollback or a
   documented compensation boundary for mutations.
4. Preserve the read-only default profile.
5. Add a test that exercises the contract or the failure mode being changed.

## Local checks

```bash
python -m unittest discover -s tests -v
python scripts/verify_release.py
```

Set `GODOT_BIN` to a Godot 4.7.2 console executable to run the addon parse smoke
test. For rendering changes, record the OS, renderer, graphics API, GPU, driver,
scene, resolution, and raw measurement method. Do not describe headless or
loopback results as visual GPU validation.

## Pull requests

Explain the behavior, permissions, failure modes, compatibility effect, and
tests. Avoid mixing unrelated refactors with protocol or security changes.
