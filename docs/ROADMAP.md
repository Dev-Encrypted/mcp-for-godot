# Public roadmap

This roadmap uses small releases and evidence gates. Dates are intentionally
absent; a phase advances when its acceptance criteria are met.

## M0 — Publishable foundation (0.10)

Deliverables:

- Python package, editor addon, client templates, example project
- Read-only default and explicit permission profiles
- Protocol, path, transaction, packaging, and editor-parse tests
- Architecture, security, compatibility, and validation documentation

Exit criteria:

- 65 total tools and exact profile counts pass contract tests
- Clean installation contains no machine-specific paths or credentials
- Addon loads in stock Godot 4.7.2 headless
- Public release clearly separates stock and custom native capabilities

## M1 — Reproducible vertical 2D observation

Dependencies: M0 and a redistributable test fixture.

Deliverables:

- One-command setup and launch for the minimal 2D example
- Live snapshot, timeline, and PNG evidence bundle
- Side-by-side comparison report with editor performance monitors
- Explicit origin, scope, unit, age, backend, session, and frame metadata

Acceptance:

- Five consecutive valid samples with no unexplained sequence gap
- Scene path, viewport dimensions, backend, and allowlisted label match the game
- Every compared metric documents source, scope, unit, and sample time
- Baseline and instrumented runs retain raw results and disclose uncertainty
- Capture remains unavailable without `--allow-capture`

Tests: real graphical editor/game, reconnect, stale sample, oversized payload,
two sessions, scene restart, and saved-scene hash before/after.

Risks: debugger-version drift, sampling bias, private text/image disclosure,
and readback stalls. Advance only after limits and failure states are visible to
the client.

## M2 — Safe creation workflows

Dependencies: stable revisions/checkpoints from M0 and observation from M1.

Deliverables:

- Coherent create-preview-apply-validate-undo task bundles
- Resource dependency impact before mutation
- Transaction recovery across server/editor restarts
- Human-readable change and rollback summaries

Acceptance:

- Conflicting disk/editor revisions are rejected before mutation
- Each supported mutation declares its rollback or compensation guarantee
- Crash-injection tests recover or identify a deterministic manual action
- Legacy write tools stay disabled by default

## M3 — Client interoperability

Dependencies: M1 and M2 fixtures.

Deliverables:

- Versioned acceptance harness for Codex, Claude Code, and generic MCP clients
- Vendor-neutral prompts and machine-readable outcomes
- Capability negotiation and image-content conformance cases

Acceptance:

- Each named client completes the same read, guarded-write, conflict, and image
  task on a disposable project
- Results separate transport, model decision quality, tool correctness, and
  project correctness
- No client credential or transcript is committed

## M4 — Graphics and subsystem coverage

Dependencies: stable evidence format and client harness.

Deliverables:

- Renderer resource graph and bounded render-pass summaries
- Import pipeline provenance and reimport cost
- Physics, audio, navigation, networking, and platform-domain snapshots
- Backend capability reporting instead of inferred parity

Acceptance:

- Each domain has typed schemas, explicit origin, limits, unavailable states,
  and regression fixtures
- Instrumentation cost is measured off/on at idle and representative load
- No domain exposes arbitrary engine or OS calls

## M5 — GPU and platform matrix

Dependencies: M4 instrumentation and automated fixture deployment.

Deliverables:

- Forward+, Mobile, and Compatibility runs across supported APIs
- Integrated/discrete GPU and multi-platform evidence
- Golden structural expectations plus perceptual image thresholds where useful

Acceptance:

- Results include hardware, driver, OS, renderer, resolution, warm-up, duration,
  raw samples, and confidence bounds
- Backend-specific failures do not become global compatibility claims
- Instrumentation overhead stays within a declared budget or the feature is
  disabled by default

## Candidate native hooks

Add C++ only when public APIs cannot provide a stable, correctly scoped value.
Current justified candidates are protected per-scene undo/redo identity, native
shader parsing, debugger event buffering, renderer pass timing, and stable
render-resource identifiers. Each hook needs a narrow read API, versioned
schema, feature flag, bounds, a stock-build fallback, and engine-level tests.
