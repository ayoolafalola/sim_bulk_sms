# Releasing Comeriver Messages

App ID (Android and iOS): `com.comeriver.messages` · version in `pubspec.yaml` (`1.0.0+1` = name 1.0.0, build 1).
Bump the build number (`+2`, `+3`…) for every upload; Google Play refuses a repeated build number.

## Two Android builds

| Build | Command | Sending | Use |
|---|---|---|---|
| **Direct (full)** | `flutter build appbundle` | Default messaging app; sends automatically through the SIM, background service, schedules send by themselves | Google Play submission as a default SMS handler, and sideloading |
| **Store** | `flutter build appbundle --dart-define=STORE_BUILD=true` | Messages app, one tap each; schedules post a "due" reminder | Backup if Google Play refuses the SMS permission |

The store build removes `SEND_SMS`, `READ_PHONE_STATE`, the foreground service and its permissions, `WAKE_LOCK`
and `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` (`android/app/src/store/AndroidManifest.xml`).
`test/unit/manifest_test.dart` fails if that list ever shrinks. To try the store behaviour on your phone:
`flutter run --dart-define=STORE_BUILD=true` (debug builds keep the permissions in the manifest, but the app
behaves as the store build).

Output: `build/app/outputs/bundle/release/app-release.aab` — upload this file to Play Console.

### Optional build values

| `--dart-define` | Needed for |
|---|---|
| `GOOGLE_SERVER_CLIENT_ID=…` | Gmail sending on Android (the OAuth **Web** client id), docs/GMAIL_SETUP.md |
| `GOOGLE_IOS_CLIENT_ID=…` | Gmail sending on iOS |
| `STORE_BUILD=true` | The store build above |

Email through a Mailgun-compatible API needs no build values (Settings › Email in the app).

## Release signing (one time)

1. Create your **upload key** (keep it outside the project, and back it up somewhere safe — if lost, you need Google support to reset it):

   ```bash
   mkdir -p ~/keys && keytool -genkey -v -keystore ~/keys/simbulksms-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```

2. Create `android/key.properties` (already git-ignored, never commit it):

   ```properties
   storeFile=/Users/<you>/keys/simbulksms-upload.jks
   storePassword=<the keystore password>
   keyAlias=upload
   keyPassword=<the key password>
   ```

3. Build. Without `key.properties` the release build is signed with the debug key and Gradle prints a warning;
   Google Play rejects such bundles.

4. In Play Console, keep **Play App Signing** on (default): Google holds the app signing key, you keep the upload key.

## iOS

Bundle ID, display name and icons are set. Building, signing (Apple Developer account, Xcode) and App Store
submission are covered in Phase 7 together with iOS reminders.

## Icon

Placeholder from `tool/make_icon.py`. To use a real design, replace `assets/icon/icon_full.png` (1024×1024, opaque)
and `assets/icon/icon_foreground.png` (1024×1024, transparent, art within the middle ~60%), then run
`python3 tool/make_icon.py --resize-only`.

## Before each release

See `docs/play/release_checklist.md`.
