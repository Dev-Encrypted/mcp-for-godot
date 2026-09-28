# MCP client configuration

The server uses stdio and can be launched by any MCP client that accepts a
command plus an argument array. Replace every placeholder with an absolute
local path. Forward slashes work well in Windows JSON and TOML paths.

- [`codex.readonly.toml`](codex.readonly.toml)
- [`codex.protected.toml`](codex.protected.toml)
- [`claude-code.readonly.json`](claude-code.readonly.json)
- [`claude-code.protected.json`](claude-code.protected.json)

The examples use `python -m mcp_for_godot`, which avoids depending on the shell's
console-script lookup. Point `command` to the Python executable in the virtual
environment where the package was installed.

Start with read-only. The protected examples deliberately omit
`--allow-legacy-write`. Add only the capabilities needed for the task and review
[`docs/SECURITY-MODEL.md`](../docs/SECURITY-MODEL.md).

Use one named server per project. If two AI clients need the same project,
prefer independent MCP processes with the same permission profile and avoid
concurrent writes. A profile isolates configuration and transcripts; it does
not create an operating-system security boundary by itself.

Client commands and configuration formats can change. These templates document
the stdio process contract; consult the current client documentation for the
location of its configuration file.
