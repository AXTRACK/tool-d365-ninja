# AXTRACK Ninja overlay

This fork preserves the upstream `dynamics365ninja/d365fo-cli` history and carries the AXTRACK-approved overlay in `axtrack/`.

- Overlay identity: `axtrack-local-metadata-v2`
- Approved upstream base: `ba598cc346864b41c6426b58a620e082ecc34b27`
- Manifest: `axtrack/overlay.json`
- Overlay entrypoint: `axtrack/Apply.ps1`
- Original authoritative copy during migration: `AXTRACK/Codex/Tools/NinjaOverlay/axtrack-class-members-v1/`

The overlay is **not** applied automatically to the source tree by checking out this branch. It must be applied against the exact approved upstream baseline using the existing governed Ninja update/publish procedure, then validated before release. The existing `AXTRACK/Codex/Tools/ninja-cli.json` pin and local UDE integration remain unchanged until that procedure is migrated and verified.

Do not publish a release or switch production consumers based solely on this source import.
