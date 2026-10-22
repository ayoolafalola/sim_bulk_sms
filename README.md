# Comeriver Messages

A messaging app for Android (and iPhone) that also sends **personalised messages to groups** of your contacts,
by **text from your own SIM** or by **email**, now or on a schedule. App id `com.comeriver.messages`.

- **Messages:** as your default SMS app: conversations, notifications with Reply and Mark as read, new messages,
  replies to declined calls, dual-SIM, campaign messages labelled in each conversation.
- **Contacts:** your phone's contacts, kept in sync (numbers, emails, birthdays, company, address, notes), plus
  contacts you add by hand or import from CSV. Groups, consent and a suppression list.
- **Campaigns:** Send by text, email, both, or "text, else email"; placeholders (`{first_name}`, `{company}`,
  `{birthday}`…) with fallbacks; preview and SMS-part counter; send now, once at a time, or weekly; send again.
- **Safe sending:** delay between texts, hourly/daily limits for SMS and for email, automatic pause and resume,
  opted-out and suppressed people always left out, every message tracked (sent, delivered, failed, unknown).
- **Background (Android):** a foreground service sends with the app closed; exact alarms start schedules.
- **Email:** any Mailgun-compatible API (docs/EMAIL_API.md) or Gmail with send-only access (docs/GMAIL_SETUP.md).
- **iPhone / not the default app:** texts open in the Messages app one at a time; emails still go by themselves.

No account, no server, no analytics: data stays on the phone (docs/privacy).

## Develop

Requires Flutter 3.47 (stable) and, for Android, compile SDK 36.

```bash
flutter pub get
flutter analyze
flutter test
flutter run                      # on a connected phone
```

Optional build values (`--dart-define`): `GOOGLE_SERVER_CLIENT_ID` / `GOOGLE_IOS_CLIENT_ID` for Gmail,
`STORE_BUILD=true` for the store build. See docs/RELEASE.md.

CI (`.github/workflows/ci.yml`) runs `flutter analyze` and `flutter test` on every push to `main` and on pull
requests.

## Layout

| Path | What |
| --- | --- |
| `lib/domain` | Models and pure logic: planner, state machine, limits, template renderer, email bodies |
| `lib/data` | SQLite schema (v1–v7) and repositories, contact sync engine, CSV import |
| `lib/features` | Screens: messages, campaigns, contacts, groups, scheduling, settings, setup |
| `lib/platform` | Bridges to Android/iOS (SMS, messages store, contacts, background service) and email senders |
| `lib/background` | Headless engine run by the Android foreground service |
| `android/app/src/main/kotlin` | SMS/MMS receivers, message store, contacts sync, send service, notifications |
| `ios/Runner` | Message composer and contacts bridges |
| `test` | Unit and widget tests (in-memory SQLite, fakes for every platform service) |

## Docs

- docs/DEFAULT_SMS_TEST.md — the on-phone test checklist
- docs/KNOWN_LIMITATIONS.md — what doesn't work yet (notably picture messages, which are deferred)
- docs/RELEASE.md, docs/play/* — building, signing, Play declarations and listing
- docs/EMAIL_API.md, docs/GMAIL_SETUP.md — email providers
- docs/SMS_STATE_MACHINE.md — message statuses and why "unknown" is never resent automatically
- CHANGELOG.md
