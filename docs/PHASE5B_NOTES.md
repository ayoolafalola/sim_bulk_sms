# Phase 5b notes
Adds: groups screens, campaign editor (`/campaigns/new`, `/campaigns/:id/edit`), campaign screen (`/campaigns/:id`) with send/pause/cancel/retry.
Verified with `flutter analyze && flutter test` (88 tests), including an end-to-end widget test that creates a campaign through the real router and an in-memory database.
Not yet built: campaign report/export, settings (default region, data deletion), suppression list screen, edit contact, manual CSV column mapping, Android foreground service for long runs.
