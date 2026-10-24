// Google Cloud project "comeriver-messages" (Gmail sending, docs/GMAIL_SETUP.md).
// OAuth client ids are not secrets; they identify the app to Google.

/// Android OAuth clients for package com.comeriver.messages, one per signing key. Google matches them by
/// package name and SHA-1, so the app never passes them; kept here for reference.
/// Debug key (this Mac, `flutter run`):
const googleAndroidClientId = '194874520779-dphp2os3etbvlji8pt2q5tn17ubjo3dl.apps.googleusercontent.com';
/// Upload key (SHA-1 C6:82:F7:…:76:67, release builds you install yourself):
const googleAndroidUploadClientId = '194874520779-8fatrnqd2vkt5trie8kc0un9duc0fohl.apps.googleusercontent.com';
/// Play App Signing key (SHA-1 0A:64:C2:…:C0:6C, every install from Google Play):
const googleAndroidPlayClientId = '194874520779-lop6nojneup4qfqush4a2jp08lt61097.apps.googleusercontent.com';

/// The project's **Web** client id. Android sign-in needs it (`serverClientId`). Its client secret is not
/// used by the app and must never be put in it. Override with `--dart-define=GOOGLE_SERVER_CLIENT_ID=…`.
const googleWebClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '194874520779-3a70p7hi57i8d13houuf9ckmhvc7g4a5.apps.googleusercontent.com');

/// The iOS client id (bundle com.comeriver.messages). Its reversed form is the URL scheme in
/// ios/Runner/Info.plist (CFBundleURLTypes), where GIDClientID repeats it.
const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID',
    defaultValue: '194874520779-eg217gcidsieihdi9vs4ubfmdi82515t.apps.googleusercontent.com');
