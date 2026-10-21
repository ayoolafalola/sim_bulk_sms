# Changelog
## 0.1.0 foundation
- Statuses, state machine, SMS segment estimator, template renderer, platform bridges, schema v1. analyze + tests pass (verified by maintainer).
## Phase 3 (unverified until `flutter analyze && flutter test` is run)
- Phone normalizer, CSV parser, import planner, eligibility filter, DB opener, contact repository with atomic import.
## Phase 3 verified; Phase 4a (unverified)
- Phase 3: analyze clean, 35 tests passing (maintainer-run).
- Groups repository, campaign repository with atomic immutable snapshots, pure campaign planner (eligibility, rendering, estimate), Riverpod providers + dashboard stats.
## Phase 4a, 4b, 5a verified
- Verified: `flutter analyze` clean, 75 tests passing (Flutter 3.47.7).
- Phase 4b: attempt repository, send orchestrator (Android direct send with pause/cancel/SIM-unavailable halt; iOS composer handoff), crash recovery marking in-flight recipients unknown, idempotent callbacks, campaign outcome computation.
- Phase 5a: app startup (DB open, crash recovery), GoRouter, theme, dashboard, contacts screen with CSV import preview, web entry point.
## Phase 5b (verified: analyze clean, 88 tests passing)
- Groups screen and group detail (create, rename, delete, add/remove members via a searchable multi-select picker).
- Campaign editor: name, message with variable chips, recipients from groups and/or individual contacts, fallback values for missing variables, live summary (recipients, exclusions, unknown consent, segment estimate, preview). Saving writes the snapshot and makes the campaign ready.
- Campaign screen: status and per-status counts, Send/Resume (Android, with SIM choice and a cost confirmation), one-at-a-time composer (iOS), Pause, Cancel, Delete; per-recipient retry, and resolve or knowingly re-send `unknown` recipients.
- Routes nested under `/` so every screen has a back button; dashboard links to campaigns, contacts and groups.
