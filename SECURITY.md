# Security policy

## Supported version

Security fixes target the latest public release.

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** private advisory flow for this
repository. Do not include bridge tokens, private game assets, captures, or
client transcripts in a public issue.

Include the affected version, required permission flags, a minimal disposable
project, reproduction steps, expected impact, and whether another local process
or network access is required.

## Expected boundary

MCP for Godot is designed for a trusted local workstation. Its loopback token is
not a sandbox against another process with the same operating-system account.
The server does not intentionally provide arbitrary command execution or file
access outside the configured Godot project. Enabling script writes or running
a project may execute project-controlled code with the user's permissions.
