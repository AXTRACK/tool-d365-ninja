# AXTRACK Ninja overlay

This fork preserves the upstream `dynamics365ninja/d365fo-cli` history and carries the AXTRACK-approved overlay in `axtrack/`.

- Overlay identity: `axtrack-local-metadata-v2`
- Approved upstream base: `ba598cc346864b41c6426b58a620e082ecc34b27`
- Manifest: `axtrack/overlay.json`
- Overlay entrypoint: `axtrack/Apply.ps1`
- Original authoritative copy during migration: `AXTRACK/Codex/Tools/NinjaOverlay/axtrack-class-members-v1/`

The overlay is **not** applied automatically to the source tree by checking out this branch. It must be applied against the exact approved upstream baseline using the existing governed Ninja update/publish procedure, then validated before release. The existing `AXTRACK/Codex/Tools/ninja-cli.json` pin and local UDE integration remain unchanged until that procedure is migrated and verified.

Do not publish a release or switch production consumers based solely on this source import.

## Active AXTRACK MCP architecture

The current AXTRACK development MCP is Ninja `D365FO.Mcp`, alongside `D365FO.Cli`, using shared `D365FO.Core` and the workstation `D365FO.Bridge` for authoritative metadata operations. The intended MCP mode is `MCP_SERVER_MODE=full`, not `read-only`. A running instance's effective mode and write access must still be checked on that instance before claiming runtime verification.

AXTRACK-specific changes are owned as a revision-pinned overlay (`axtrack/overlay.json`, `axtrack/Apply.ps1`); the approved upstream revision, overlay identity, installation target, and capabilities are recorded in `AXTRACK/Codex/Tools/ninja-cli.json`. The repository's source checkout alone does not prove that a new binary has been installed or activated.

The predecessor `AXTRACK/d365-metadata-service` is historical migration material, **not** an active MCP server, an active deployment target, or the source of current mode settings. Its archived NAS/read-only configuration must not be used to describe the current Ninja MCP.
