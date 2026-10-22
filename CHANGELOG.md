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
## Phone fixes and contacts import (analyze clean, 97 tests)
- Material icons bundled; Android sent/delivered callbacks now reach the app (receiver filter accepts the `smsattempt` data scheme).
- Import from phone: native read-only contacts reader (Android/iOS), search by name or number, select all shown, add to an existing or new group (numbers already saved are reused, invalid ones skipped).
## Scheduling step 1: resend, schedules, schema v2 (analyze clean, 128 tests; not yet run on a device)
- Schema v2 (migrates v1 in place): campaigns store their audience (groups/contacts) and fallbacks, link to the campaign they were created from, and can have one schedule.
- Send again on finished campaigns: to the same people (minus newly opted-out/suppressed) or to everyone in the groups now. Creates a new campaign; the original and its report are unchanged.
- Schedules: once (sends that ready campaign as approved) or weekly on chosen days at a time, optional end date. Weekly runs re-read the groups and become their own campaigns with their own reports.
- Rules: up to 2 hours late is sent, later is skipped as missed; never overlaps another send; blocked messages and empty audiences are recorded, not sent. Pause/resume/edit/remove from the campaign screen; Scheduled list on the dashboard.
- Due runs start while the app is open (on launch, on resume, every 30 s). Background sending with the app closed is step 2.
## Scheduling step 2: Android background sending (analyze clean, 137 tests; native code not yet built or run)
- All Android sending (manual and scheduled) runs in a foreground service (`SendService`, special-use type) hosting a headless Flutter engine (`backgroundMain`) that reuses the tested queue, state machine and scheduler. Sends continue when you leave or close the app.
- Exact alarm (`WakeScheduler`) wakes the service at the next scheduled run; re-armed after reboot, app update and exact-alarm permission changes (`WakeReceiver`). Without exact-alarm permission, runs start only while the app is open.
- Pause and Cancel work across engines through the database (the sender checks the campaign status before every message). A cancelled recipient can never be sent.
- After the last message the service waits up to 2 minutes for sent/delivery reports, then stops; later reports are not recorded.
- Notifications: ongoing progress while sending; results ("finished — 48 delivered, 2 failed", skipped, blocked, not sent and why).
- Background sending setup screen (notifications, Alarms & reminders, battery unrestricted, Samsung "Never sleeping apps" hint), linked from the dashboard and the schedule screen; dashboard warns when schedules exist but setup is incomplete.
- Crash recovery is skipped at app start while the service is sending; the service runs it when it starts. SQLite `busy_timeout` set because the app and the service each hold a connection.
