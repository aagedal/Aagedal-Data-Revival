# Changelog

All notable changes to Aagedal Data Revival are recorded here. The project uses
[Semantic Versioning](https://semver.org/) after the first stable release.

## Unreleased

### Added

- Native macOS workflow for imaging owned SD, microSD, and CFexpress cards and
  scanning existing raw disk images.
- Temporary, path-specific, read-only raw-device authorization without an
  installed privileged helper or background service.
- Resumable GNU ddrescue imaging with source identity checks, mapfile progress,
  cancellation, remount, and eject controls.
- PhotoRec recovery profiles for JPEG and common camera RAW families.
- Persistent recovery sessions, honest validation labels, Quick Look previews,
  filtering, collision-safe export, and recoverable cleanup.
- Reproducible arm64 recovery-engine builds with pinned sources, licenses,
  notices, corresponding source, and a signed-bundle audit.
- GPLv3-or-later application licensing with an in-app notice and bundled full
  license text.
- A versioned JPEG recovery-quality benchmark and deterministic UI workflow.
- VoiceOver descriptions for recovery and imaging state, plus keyboard shortcuts
  for the primary open, cancel, export, and rescan actions.
- A clean-checkout release-candidate command that creates the Developer ID
  archive, notarizes and staples it, runs the bundle and Gatekeeper gates, and
  emits the versioned ZIP with its SHA-256 checksum.
- Release-ready product wording without pre-release branding in the application
  or current user documentation.

### Known limitations

- Version 1.0 supports Apple silicon Macs running macOS 14 or newer.
- MOV/MP4 recovery and metadata-aware filesystem recovery are not included.
- Camera RAW support is not yet qualified by representative redistributable
  fixtures, and a readable preview does not prove full sensor-data integrity.
- Fragmented, truncated, and overwritten files may be partial or unrecoverable.

## Release history

No public release has been published yet.
