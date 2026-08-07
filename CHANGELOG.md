# Changelog

## [3.0.0] - 2026-08-07

### Added

- Added the unified provider registry, credential health states, model catalog management, routing traces, target bindings, agent routing, session support, and voice/realtime safety models.
- Added provider-aware routing with credential gates, retry/failover policies, request profiles, usage tracking, and secure secret handling.
- Added Models-page status summaries, catalog controls, localized onboarding, consistent empty states, and account/provider usage views.
- Added RouterHost loopback data/control-plane isolation and authenticated shutdown/control flows.

### Changed

- Split the Models page into focused Providers, Catalog, Routes, and Usage components.
- Migrated Codex catalog synchronization to include v2 registry entries while preserving native models and legacy v1 providers during migration.
- Updated the macOS app bundle identity and release product name to `icopool.app`.
- Completed localization key parity across all 11 supported languages.

### Fixed

- Fixed stale provider split-state summaries after proxy start, stop, refresh, and launch recovery.
- Fixed v2 provider configuration not reaching ChatGPT.app's model catalog or local runtime routing.
- Fixed missing Codex configuration creation on first proxy/catalog setup.
- Fixed usage views ignoring account-level provider metrics and account card layout drift.
- Fixed Xcode project source coverage so all Swift sources and tests are included in their targets.

### Verification

- Swift source parsing, Domain typechecking, PBX syntax validation, localization key parity, duplicate-key checks, and secret scans were run.
- Full `swift build` / `xcodebuild` / XCTest execution remains blocked in this environment because only CommandLineTools are active and `SwiftUIMacros`/full Xcode are unavailable.
