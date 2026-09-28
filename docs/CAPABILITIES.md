# Capability model

MCP for Godot separates discovery, observation, execution, and mutation. The
server advertises only tools allowed by the startup flags. Runtime dependencies
are then reported as structured availability results.

## Read-only baseline

The 20-tool default profile can enumerate supported project files, read bounded
text, inspect editor and scene state, inspect graphics metadata, read live
snapshots and timelines, query dependencies, view managed-process logs, and
report the server's capability set.

Read-only describes project mutation. These tools may disclose filenames,
scene structure, selected UI text, imported-resource metadata, runtime metrics,
and process output to the MCP client.

## Validation and lifecycle

`--allow-run` exposes seven additional tools in the absence of write access.
They validate a project and manage editor or game processes owned by the server.
A server never stops a process it did not start unless the editor bridge returns
the matching ownership token.

## Guarded mutations

Checked editor mutations require the expected scene path and graph revision.
File transactions require expected hashes, produce a preview, recheck state
before apply, and write a persistent checkpoint. Scene history operations bind
undo/redo to an exact history identity, action index, and name.

Rollback guarantees vary:

- Script and resource transactions can restore checkpointed bytes if the
  current hash still matches.
- A newly created resource can be removed only if it has not gained consumers.
- Import rollback restores `.import` configuration and reimports; it does not
  restore the engine's derived cache byte for byte.
- Editor scene operations use the native undo history when the required hook is
  available.

## Live observation

The runtime collector reports a bounded 2D projection and public performance
monitors. A snapshot includes its origin, run identity, sample sequence, age,
scene path, renderer/backend fields, collection cost, and flow-control state.
The timeline describes changes between retained samples. `stale` means the last
valid sample is older than the freshness target; it is not a current reading.

Image evidence is sampled separately. Metadata records the image frame and the
nearby telemetry samples; it does not claim they came from the same rendered
frame. See [LIVE-TELEMETRY.md](LIVE-TELEMETRY.md).

## Complete tool list

The generated [tool catalog](TOOLS.md) lists all 65 tools, their summaries, and
the startup flags controlling visibility.
