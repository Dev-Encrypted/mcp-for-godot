# Validation policy

## Automated checks

Every change should pass:

```bash
python -m unittest discover -s tests -v
python scripts/verify_release.py
```

The suite validates both MCP protocol generations, tool counts per permission
profile, schema failures, project confinement, transaction recovery behavior,
addon completeness, and the absence of machine-specific paths in publishable
files.

When `GODOT_BIN` points to a console executable, the suite also creates a fresh
temporary project, installs the addon, enables it, launches the real editor in
headless mode, and rejects parse or plugin-load errors.

## Evidence levels

| Level | What it proves | What it does not prove |
|---|---|---|
| Static/package | Files, imports, schemas, no known local paths | Runtime behavior |
| Unit/contract | Deterministic server and transaction behavior | Editor or GPU behavior |
| Headless editor | Addon parses and initializes in that build | Presented pixels or driver health |
| Real editor/game | End-to-end bridge and runtime flow | Other GPUs/backends/clients |
| Real client task | One client/model used tools correctly | Universal model compatibility |
| GPU matrix | Measured behavior on recorded systems | Unmeasured systems |

Release notes must state which levels actually ran.

## Acceptance for a client claim

A Codex, Claude, or other-client compatibility claim requires a recorded task
that checks discovery, read-only inspection, permission refusal, one guarded
mutation in a disposable copy, conflict recovery, and interpretation of a live
image. Authentication profiles and transcripts must remain outside the public
repository and be reviewed for secrets before sharing summaries.
