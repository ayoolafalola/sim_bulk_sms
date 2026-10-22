# Release checklist

1. `flutter analyze && flutter test` — all green.
2. Bump `version:` in `pubspec.yaml` (build number must increase every upload).
3. Signing set up (`android/key.properties`, see docs/RELEASE.md).
4. Build: `flutter build appbundle` (full) — or `flutter build appbundle --dart-define=STORE_BUILD=true` (store).
5. Install the release build on a phone (`flutter install --release` or via internal testing) and run:
   setup flow, send to 2 own numbers, schedule 2 minutes ahead with the app closed, CSV import.
6. Privacy policy live on GitHub Pages; URL in Play Console and store listing.
7. Play Console: create the app (name "SIM-based Bulk SMS", default language, App, Free), complete App content
   (privacy policy, ads, app access + reviewer_notes.md, content rating, target audience, data safety,
   permission declarations), store listing (store_listing.md + graphics).
8. Upload the .aab to **Internal testing** first, install from Play on your phone, then promote to Production.
9. If the SMS declaration is refused: build the store version (step 4, store), bump the build number, remove the
   SMS/foreground-service declarations, upload again.
