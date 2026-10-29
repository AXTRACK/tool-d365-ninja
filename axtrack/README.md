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

The current AXTRACK development MCP is Ninja `D365FO.Mcp`, alongside `D365FO.Cli`, using shared `D365FO.Core` and the workstation `D365FO.Bridge` for authoritative metadata operations. The active Ninja deployment is configured for `MCP_SERVER_MODE=full`. Verify the effective process configuration and installed binary independently after each deployment.

AXTRACK-specific changes are owned as a revision-pinned overlay (`axtrack/overlay.json`, `axtrack/Apply.ps1`); the approved upstream revision, overlay identity, installation target, and capabilities are recorded in `AXTRACK/Codex/Tools/ninja-cli.json`. The repository's source checkout alone does not prove that a new binary has been installed or activated.

The predecessor `AXTRACK/d365-metadata-service` is historical migration material, **not** an active MCP server, an active deployment target, or the source of current mode settings. Its archived NAS/read-only configuration must not be used to describe the current Ninja MCP.

## MCP AOT creation, current release candidate

The MCP `generate_object` tool supports `objectType=enum` and `objectType=edt` through the same Ninja scaffolders as CLI:

- No destination: XML-only response, unchanged behavior.
- `out`: guarded atomic scaffold file write, **not** proof of AOT installation.
- `installTo`: bridge-backed `createObject` using `D365FO.Bridge` and `IMetadataProvider`; record a Ninja undo-journal entry, require live metadata provider read-back, fail closed without the bridge, and reject `overwrite` for create.
- Enum: `values` accepts `Name:IntValue[:Label]` or legacy bare names; `nonExtensible` is optional. EDT: `baseType`, `enumType`, `extends`, `size` and `label`.

The Ninja undo journal does **not** replace the WorkItem Implement journal. The sole lifecycle owner is `AXTRACK/Codex/Plugins/d365fo-workitem/skills/d365fo-workitem/scripts/lifecycle_state.py`, with its existing `implement-*` commands. The MCP tool accepts `ticketId` (not a client-selected path) and resolves the WorkItem from the operator-pinned `D365FO_IMPLEMENT_WORKITEMS_ROOT/index.json`. WorkItem target registration, pre-state, final receipt, validation closure and completion still require that canonical journal. Calling Ninja generation does not itself mark WorkItem Implement complete. This change does not execute or authorize `+fo implement 64120`.

Deployment remains a separate step: the source and overlay need to be published, the installed UDE binary and `tools/list` must be verified, and AOT create/read-back requires live UDE evidence. The pinned upstream and installation contract in `AXTRACK/Codex/Tools/ninja-cli.json` are unchanged here.
