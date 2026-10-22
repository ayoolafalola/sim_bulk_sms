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
## Redesign Part A: navigation and design system (analyze clean, 208 tests)
- New look from the approved mockup: Plus Jakarta Sans (bundled, OFL licence in assets/fonts), deep-green brand on a warm off-white ground, white rounded cards, status tags with text labels, progress bars, friendly empty states with one next step, polished dark mode. All in `lib/app/theme.dart` (tokens in `AppColors`) and `lib/features/common/ui.dart`.
- Bottom navigation (Campaigns · Contacts · Settings); each tab keeps its own history, detail and form screens open full screen above it. A dot on Settings while required setup is missing.
- Campaigns home: this week's sends and delivery rate, scheduled runs, drafts (open straight into the editor) and recent campaigns with progress and plain-language detail.
- Contacts tab: People and Groups in one place, quick From phone / From file / Add one, SMS and Email badges, contact actions in a bottom sheet, add-contact sheet with optional email.
- Settings tab: how sending works on this phone, sending safety, app setup status, default country, version.
- Fewer interruptions: deleting a contact, removing a group member and deleting a draft show Undo instead of asking first (sent campaigns still confirm, as history would be lost).
- Fixed along the way: duplicate floating-button animation tags across tabs; list ripples hidden by a coloured background.
## Fix: "No active SIM was found"
- The app treated "can't list SIMs" (needs the Phone permission) as "no SIM". It now checks whether a SIM is ready via Android's SIM state (no permission needed); without the Phone permission it sends through the default SIM. The Phone permission is only needed to choose between two SIMs. Message for a real missing SIM: "No SIM card is ready. Insert a SIM or turn off airplane mode."

## Part B1: default messaging app — receive and read (analyze clean, 215 tests; native code not yet built)
- Android components required for the default-SMS role: SMS_DELIVER receiver (stores incoming texts, notifies), WAP_PUSH_DELIVER MMS receiver (placeholder notice until Part C), "send to" compose alias (sms:, smsto:, mms:, mmsto:), RESPOND_VIA_MESSAGE quick-reply service. New permissions READ_SMS, RECEIVE_SMS, RECEIVE_MMS, RECEIVE_WAP_PUSH, WRITE_SMS (all removed again in the store build).
- Every outgoing text (personal and campaign) is written to the phone's message store with sending → sent / failed / delivered, so history is kept if the user switches apps. Personal sends update their status through a manifest receiver, even with the app closed.
- Becoming default: Android's role prompt from setup, the Messages tab, the campaign screen and App setup; falls back to the default-apps settings page. Direct sending now requires being the default app (Google Play rule); otherwise the Messages-app flow is used.
- Messages tab (first tab, unread badge): conversations with contact names, unread counts, search, All / Unread / Campaign replies. Conversation: day labels, bubbles with Sending / Sent / Delivered / Not sent (tap to retry), quick replies, reply box. Opens directly from a notification or from another app's "Send SMS" with the draft.
- Empty states scroll on short screens (found by tests: overflow with a tall setup banner).

## Fix: "not the default app" while it is; rename to Comeriver Messages
- Default-app detection now asks Android's role manager (`RoleManager.isRoleHeld(ROLE_SMS)`, Android 10+). `Telephony.Sms.getDefaultSmsPackage` returned null on Android 16 although the app held the SMS role, so the inbox stayed hidden and automatic sending was blocked.
- App name is now **Comeriver Messages** (Android label, iOS display name and contacts prompt, in-app text, store listing, privacy page, docs). The app ID stays `com.comeriver.simbulksms.app`.
- App ID changed (before first release) to `com.comeriver.messages` on Android and iOS. On a test phone this installs as a new app: set it as the default messaging app again; earlier test data stays with the old app.

## Part B2: messaging app, the rest (analyze clean, 222 tests; native changes not yet built)
- New message: pick people from app contacts, phone contacts or a typed number; several recipients each get their own text.
- Incoming-text notifications have Reply (inline) and Mark as read, working with the app closed (`NotificationActionReceiver`).
- Campaign texts are linked to their row in the phone's message store (schema v5 `stored_messages`); conversations label them "Campaign · <name>" and the label opens the campaign.
- Long-press a message: Copy, or Delete with Undo. Long-press a conversation: Mark as read, Delete conversation (confirmed). Mark all as read on the Messages tab.
- Dual-SIM: a SIM chip on the reply bar, defaulting to the SIM the person last texted you on, remembered per conversation.
- Conversation header shows the person's groups; menu: Add to contacts, Add to group…, Delete conversation.

## Part D1: phone-synced contacts (analyze clean, 233 tests; native changes not yet built)
- Contacts tab asks once: "Use your phone's contacts?" On yes (and Contacts access), everyone in the phone's Contacts appears here and stays in sync: on launch, on return to the app, and shortly after any change in the Contacts app. "Not now" syncs nothing; Settings › Contacts › Sync phone contacts turns it on or off, with Sync now.
- Contacts follow the phone's format (schema v6): every number and email with labels, birthday and other dates, company, job title, address and note. Texts go to the number you pick (else the phone's default, else Mobile); same for email. Contacts with neither are skipped.
- Contacts deleted on the phone are removed here. Hand-added and file-imported contacts stay app-only. An app contact with the same number as a phone contact becomes that phone contact, keeping its consent, groups and history.
- New contact screen: Message, Add to group, numbers/emails ("used for texts"), dates, company, address, note, groups, consent, suppress. Edit opens the phone's Contacts app for phone contacts (changes sync back); app-only contacts are edited in the app and can be deleted (with Undo).
- Contacts tab: tap opens the contact; long-press or Select picks several, Select all, Add to group (or a new group). "From phone" one-off import is shown only while sync is off; group "Add from phone" likewise.
- New campaign placeholders: {company} and {birthday}.
- Two phone contacts may share a number; numbers added in the app stay unique.

## Part D2 + D3: email (analyze clean, 256 tests; native/plugin changes not yet built)
- Campaigns choose **Send by**: Text · Email · Text and email · Text, or email if no number; an email subject
  (placeholders work) and an email preview. Each person gets one row per channel; the campaign screen shows SMS
  and Email counts separately and each row's number or address.
- **Settings › Email:** Off · **Mailgun API** (any Mailgun-compatible service: base URL, sending domain, API key,
  From name/address) · **Gmail** (send-only `gmail.send`, via `google_sign_in` 7.2; needs Google client ids at
  build time, docs/GMAIL_SETUP.md). Email limits (default 50/hour, 400/day), unsubscribe line (on by default,
  plus `List-Unsubscribe`), **Send test email**.
- Emails send by themselves everywhere: with texts in the Android background service; on iPhone or when this
  isn't the default app, emails go first and texts follow the usual flow. Scheduled email-only campaigns run
  automatically; mixed scheduled runs send their emails and wait for you for the texts.
- Outcomes: 2xx sent (provider id stored), 4xx failed, 5xx/timeout **unknown** (never resent automatically).
  A refused API key or wrong address pauses the campaign. Gmail tokens refresh once on 401; if Google needs a
  new sign-in the run doesn't start and you're told why.
- Schema v7 (campaign channel and subject; recipient channel, email and subject). Contacts can be added with
  only an email. `INTERNET` permission in the main manifest (release builds need it for email).
- Docs: docs/EMAIL_API.md, docs/GMAIL_SETUP.md.

## Part E: Play and privacy update (docs only)
- Play declarations now use **Default SMS handler** (with a video script), data safety answers for email,
  reviewer notes, release checklist (Part C first, Gmail build values), store listing, privacy policy (SMS app,
  contacts sync, email providers, Gmail Limited Use).

## Phase 6: README and CI
- README rewritten. GitHub Actions runs `flutter analyze` and `flutter test` on pushes to `main` and pull requests.
- Part C (picture messages) is deferred. Submitting without it is allowed; the Play docs record the review risk.
- Publisher details: Comeriver Limited, messages@comeriver.com, https://messages.comeriver.com. Privacy policy
  for https://messages.comeriver.com/privacy and a draft terms of use (docs/terms) for /terms; Play, store
  listing and Gmail consent-screen docs point there.
