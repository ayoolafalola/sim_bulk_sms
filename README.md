# SIM Bulk SMS (work in progress: foundation slice)

Flutter app: Android sends directly through the SIM via `SmsManager`; iOS hands each message to the native `MFMessageComposeViewController` (the user taps Send).

## Status: what exists vs. what does not
Authored without Flutter/Dart/Kotlin/Swift toolchains or network access. The foundation slice passes `flutter analyze` and its unit tests (run by the maintainer). The Phase 3 files (phone normalizer, CSV import, repositories) are **not yet verified**. Kotlin and Swift have never been compiled. Run `flutter create . --org app.sim_bulk_sms --project-name sim_bulk_sms` in this folder first (it generates the missing Gradle/Xcode scaffolding without overwriting these files; re-check `MainActivity.kt` and merge the manifest snippet), then `flutter pub get && flutter test`.

Implemented (unverified): statuses and state machine, GSM-7/UCS-2 segment estimator, template renderer with unresolved-variable blocking, capability/service abstraction, Android `SmsBridge.kt` (permissions, SIM listing, single/multipart send, per-part callbacks, delivery reports), iOS `MessagingBridge.swift`, SQLite schema v1, unit tests.

Not yet implemented: UI/screens, Riverpod/GoRouter wiring, repositories, CSV and contact import, phone normalization, persistent send queue and recovery, reports/export, settings, data deletion, CI, remaining docs.

## Release gates
1. Google Play restricts `SEND_SMS`; direct sending stays disabled (`PLAY_SMS_POLICY_RESOLVED=false`) until eligibility is confirmed. Verify the current policy: https://support.google.com/googleplay/android-developer/answer/9888170
2. Android native code must be tested on real single/dual-SIM hardware; iOS on real iPhones.
