// Google Cloud project "comeriver-messages" (Gmail sending, docs/GMAIL_SETUP.md).
// OAuth client ids are not secrets; they identify the app to Google.

/// Android OAuth client for package com.comeriver.messages. Google matches it by package name and
/// signing-key SHA-1, so the app never passes it; kept here for reference.
const googleAndroidClientId = '194874520779-dphp2os3etbvlji8pt2q5tn17ubjo3dl.apps.googleusercontent.com';

/// The project's **Web** client id. Android sign-in needs it (`serverClientId`). Its client secret is not
/// used by the app and must never be put in it. Override with `--dart-define=GOOGLE_SERVER_CLIENT_ID=…`.
const googleWebClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID',
    defaultValue: '194874520779-3a70p7hi57i8d13houuf9ckmhvc7g4a5.apps.googleusercontent.com');

/// The iOS client id (and its reversed form in ios/Runner/Info.plist). Empty: Gmail is off on iPhone.
const googleIosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID', defaultValue: '');
