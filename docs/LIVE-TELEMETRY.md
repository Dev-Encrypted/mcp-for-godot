# Live telemetry

## Collection path

1. An explicitly attached runtime probe waits for rendered frames.
2. At a bounded interval it projects selected scene and viewport data.
3. The Godot debugger channel carries the sample to the editor addon.
4. The addon validates size, schema, session identity, and sequence.
5. MCP tools read the last accepted snapshot or a retained timeline window.

The MCP request does not call `RenderingServer` inside the game on demand. It
reads data already accepted by the editor.

## Limits

- One active probe per game process
- At most 300 projected nodes
- At most 8 viewports
- At most 128 KiB per telemetry message
- At most one sample per second by default
- At most 40 retained timeline events per read
- UI text only from explicitly allowed paths and at most 160 characters
- PNG at most 2048 pixels on either side and 256 KiB encoded

These limits reduce editor stalls and accidental disclosure. A rejected sample
does not replace the last valid one; that prior sample becomes stale and the
error is exposed.

## Flow control

The probe waits for an acknowledgement before collecting another full sample.
Skipped intervals are counted. Sequence gaps, rejected samples, collection
microseconds, and prior send-call microseconds are separate fields. None of
those values alone measures GPU rendering time.

## Correlation

Snapshots, timeline events, images, debugger errors, and editor scene state use
different clocks and collection paths. Combined evidence reports run/session
identifiers and frame differences. A read performed after an image capture can
still contain a sample from an older frame.

## Comparison with the editor

For a useful validation:

1. Run one known scene and record the backend and viewport size.
2. Read `godot_live_snapshot` and the editor's debugger monitors close together.
3. Compare monitor names, scope, units, and timestamps before comparing values.
4. Repeat across a stable interval and report sampling differences.
5. Use an image only as evidence of visible output at its recorded frame.

Equal numbers in one fixture do not prove equal scope in all scenes.
