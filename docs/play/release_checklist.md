# Release checklist

1. `flutter analyze && flutter test` — all green (CI runs them on every push).
2. Bump `version:` in `pubspec.yaml` (build number must increase every upload).
3. Signing set up (`android/key.properties`, see docs/RELEASE.md).
4. Build: `flutter build appbundle` (full) — or `flutter build appbundle --dart-define=STORE_BUILD=true` (store).
   With Gmail: add `--dart-define=GOOGLE_SERVER_CLIENT_ID=… --dart-define=GOOGLE_IOS_CLIENT_ID=…` (docs/GMAIL_SETUP.md).
5. Install the release build on a phone (`flutter install --release` or via internal testing) and run:
   docs/DEFAULT_SMS_TEST.md (become default, receive/reply, campaign, contacts sync, email test, switch back).
6. Privacy policy live at https://messages.comeriver.com/privacy (and terms at /terms); URL in Play Console, store
   listing and, with Gmail, the Google OAuth consent screen.
7. Play Console: create the app (name "Comeriver Messages", default language, App, Free), complete App content
   (privacy policy, ads, app access + reviewer_notes.md, content rating, target audience, data safety,
   permission declarations), store listing (store_listing.md + graphics).
8. Upload the .aab to **Internal testing** first, install from Play on your phone, then promote to Production.
9. If the SMS declaration is refused (for example over picture messages), either build Part C and resubmit, or
   build the store version (step 4, store), bump the build number, remove the
   SMS/foreground-service declarations, upload again.
