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
## Release Phase 1: usability and drafts (analyze clean, 142 tests)
- Bottom buttons are never hidden: list screens leave room for the Android gesture/navigation bar (extra space at the bottom of the dashboard, room under floating buttons), and form buttons (Save and review, Save schedule, Add to group) sit in the page so they rise above the keyboard.
- New campaigns autosave as a draft shortly after each change (name, message, recipients, fallbacks); "Draft saved" shows in the title bar and "Saved as a draft" on leaving. Drafts open straight back into the editor from the dashboard; the campaign screen offers "Continue editing". Saving turns the same draft into a ready campaign.
- Editing a ready campaign never turns it back into a draft; leaving with unsaved edits asks "Discard changes?".
## Release Phase 2: safer bulk sending and text counter (analyze clean, 167 tests)
- Message text counter under the message box: characters, SMS count and room left, using the longest real message once recipients are picked. Special characters that force 70-character SMS are named, with a one-tap "Use plain characters" fix for keyboard smart quotes, long dashes, ellipsis and non-breaking spaces.
- Settings hub (gear on the dashboard) with Send settings: delay between messages (1–30 s, default 3 s), hourly limit (default 100) and daily limit (default 300), each switchable off, default country for numbers (with dialing codes), and recent usage. Stored in the database (schema v3) so the background service uses them.
- Limits use rolling 60-minute / 24-hour windows of messages sent from this phone. At a limit the campaign pauses with the reason and resume time, a notification says so, and the background service resumes it automatically (the wake-up alarm covers resumes as well as schedules). Pausing yourself cancels the automatic resume. Starting or resuming while at a limit waits for it.
- Send confirmation shows how long the send takes and, with the limits, roughly when it finishes. The schedule screen warns when one run is bigger than the daily limit.
## Release Phase 3: CSV import with column mapping (analyze clean, 186 tests)
- Picking a CSV now opens an Import screen: "First row is headers" (detected automatically), column pickers with sample values for Name or First + Last name, Phone and Email, and a live preview of the first rows as they'll be saved.
- Columns are detected from many header names (surname, other names, GSM No., WhatsApp, mobile, cell, e-mail…) or, without recognisable headers, from the contents (the column of phone numbers, the text column, the column with '@').
- Summary of what will happen (new, already in contacts, repeated in the file, invalid, no name, blank), "See skipped rows" with line numbers and reasons, and an option to use the number as the name for rows without one. Cells with several numbers use the first and say so.
- Optional "Add everyone to a group" (existing or new); people already in your contacts are added to the group too. Contacts, group and memberships are saved in one transaction: on failure nothing is saved.
- Files saved by Excel on Windows decode correctly (Windows-1252 fallback); Excel workbooks get "Save as CSV UTF-8" instructions; files over 20,000 rows are refused with a request to split them; large files are parsed off the UI thread.
## Release Phase 4: onboarding, permission warnings, Messages-app fallback (analyze clean; native code not yet built)
- First-launch setup (once per install, also shown once after updating): welcome, then one screen per item with why it's needed — Send SMS, Notifications, Alarms & reminders, Battery unrestricted (with Samsung steps), Contacts (optional) — then default country and a summary. Required items can be skipped but stay flagged.
- App setup checklist (Settings › App setup, replaces Background sending) with live status and a fix button per item. Permissions refused for good are detected (Android stops asking) and the button opens app settings with instructions.
- Persistent warnings until fixed: a non-dismissible dashboard banner listing missing required items and their effect, a dot on the Settings gear, warnings on the schedule screen, all re-checked whenever you return to the app.
- Messages-app fallback (Android, when SMS permission is off or automatic sending isn't allowed): "Open next message (n of N)" opens the default Messages app with the number and text filled in; back in the app, "Did you send it to …?" records Sent (confirmed by you) or Not sent (can be resent). "Turn on automatic sending" asks for the permission. Scheduled runs in this mode are prepared and you're notified to send them.
- Layout fixes found by the new tests: campaign status row and onboarding buttons no longer overflow on narrow screens or large text sizes.
## Release Phase 5: release setup (version 1.0.0+1)
- Identity: name "SIM-based Bulk SMS" (Android string resource, iOS display name, in-app), app ID `com.comeriver.simbulksms.app` on Android and iOS, target API 36.
- Two Android builds from one codebase: full (default) and store (`--dart-define=STORE_BUILD=true`). The store build merges `src/store/AndroidManifest.xml`, removing SMS, phone-state, foreground-service, wake-lock and battery-exemption permissions and the send service; it sends through the Messages app, and its schedule alarm posts a "campaign is due" reminder. Setup and warnings only ask for what each build uses. `test/unit/manifest_test.dart` guards the permissions and identity.
- Release signing from git-ignored `android/key.properties`; without it Gradle warns loudly and uses the debug key.
- Placeholder icon (SIM card + message bubble on green) generated by `tool/make_icon.py` for Android (legacy + adaptive + themed) and iOS.
- Docs: `docs/RELEASE.md` (builds, signing, icon), `docs/play/` (store listing, permission declarations incl. SMS "Device automation" request and foreground-service video script, data safety, reviewer notes, release checklist), `docs/privacy/` (privacy policy page for GitHub Pages + publishing steps).
