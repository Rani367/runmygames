# Changelog

All notable changes to RunMyGames are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-11

First public release.

### Added

- One-line installer: `curl -fsSL https://raw.githubusercontent.com/Rani367/runmygames/main/install.sh | bash`.
- Prebuilt Wine engine download with checksum verification, so there's no 45-minute build on first run.
- Setup assistant that walks through engine download, prefix creation and Steam install.
- Live library: shows which game is running, full keyboard navigation and VoiceOver support.
- Per-game settings sheet (renderer, HUD, MetalFX, Retina, launch arguments, environment variables).
- Notifications when a new RunMyGames version is available.
- New CLI commands: `rmg engine`, `rmg diagnose`, `rmg uninstall`, `rmg update` and `rmg d3dmetal`.
- **Copy Diagnostics** in the Help menu, for bug reports.
- Automatic renderer detection for engines that load their renderer at runtime (Source 2, Godot).

### Fixed

- Steam no longer closes while a game started by a launcher is still running: the shim now waits for the
  whole process tree using a Windows Job object.
- Automatic renderer switching after a crash no longer loops between renderers.
- The per-game Retina override can be reset back to the global default.
- Launchers created from the app point at the right binary and report errors instead of failing silently.
- A race at startup that could close Steam automatically right after it opened.
- A corrupt `localconfig.vdf` for one Steam account no longer blocks the others.
- Logs are rotated instead of growing forever.

### Changed

- Library scans are cached until a game updates, making refresh and launch much faster.
- Settings changes apply immediately.
- DXMT is listed under its correct license (LGPL) in the README.

[Unreleased]: https://github.com/Rani367/runmygames/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Rani367/runmygames/releases/tag/v1.0.0
