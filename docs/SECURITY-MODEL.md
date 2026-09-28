# Security model

## Protected assets

- Project files and imported resources
- Unsaved editor state and undo history
- Runtime text, scene structure, screenshots, and performance data
- GDScript code and project-controlled processes
- Local MCP transcripts and bridge credentials

## Boundaries

The MCP client and server run as the current operating-system user. The editor
bridge is bound to `127.0.0.1` and authenticates each request with a 256-bit
random token created by the addon. The token and port are stored in the selected
project's `.godot/ai_mcp/bridge.json`.

This boundary prevents accidental remote exposure and cross-project attachment.
It does not protect against a process with the same user identity and read
access to the project. Use operating-system accounts or a VM for adversarial
local isolation.

## Permission flags

| Flag | Adds | Main risk |
|---|---|---|
| none | 20 read-only tools | Disclosure of permitted project/runtime data |
| `--allow-run` | validation and owned processes | Project code may execute |
| `--allow-write` | checked editor and file mutations | Project state may change |
| `--allow-capture` | viewport PNG and combined evidence | Private visual content may leave the game |
| `--allow-input` | allowlisted InputMap actions | Running game behavior changes |
| `--allow-script-write` | guarded `.gd` transactions | New code may execute when later loaded |
| `--allow-legacy-write` | seven older mutation shortcuts | Weaker preconditions and recovery |

`--allow-script-write` is useful only with `--allow-write`; applying scripts and
resource operations may also require `--allow-run`. Tool discovery filters
capabilities that cannot work under the active flags.

## Controls

- One resolved project root per process
- `res://` paths only, with length and suffix allowlists
- Rejection of traversal, hidden path components, symbolic links, and junctions
- JSON and bridge line limits of 1 MiB
- Input schemas with bounded arrays, strings, numbers, and object keys
- Expected scene revisions and asset hashes for checked mutations
- Per-project operating-system lock for file transactions
- Managed-process ownership tokens for start/stop operations
- Live sample tree, viewport, image, frequency, and retention limits
- Audit summaries that exclude tokens and full script bodies

## Operations that execute code

Running or importing a Godot project can execute project-controlled scripts,
editor plugins, import plugins, or native extensions. Loading scenes containing
`@tool` code can also execute code in the editor. The server requires explicit
run permission for known paths that cross this boundary, but it cannot make an
untrusted Godot project safe. Review and isolate untrusted projects before use.

## Operational guidance

1. Start with the read-only profile.
2. Use a clean version-control worktree for mutations.
3. Grant only the flags needed for the current task.
4. Keep one editor and one MCP server attached to a project during writes.
5. Review diffs, checkpoints, and audit records before accepting generated work.
6. Never publish `.godot/ai_mcp`, captures, transcripts, or client profiles
   without checking them for private content.
7. Avoid legacy writes except in disposable migration fixtures.

## Out of scope

- Isolation from malicious processes running under the same OS account
- A sandbox for untrusted game code, editor plugins, GDExtensions, or importers
- Remote or multi-user bridge access
- Automatic approval of AI-generated changes
- Proof of visual correctness based only on headless execution
