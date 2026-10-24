# Sending campaign email through Gmail

Settings › Email › **Gmail** sends from the user's own Gmail account through the Gmail API, with only the
**send-only** permission (`https://www.googleapis.com/auth/gmail.send`). The app can't read anyone's mail.

Gmail needs a Google Cloud project with OAuth client ids, passed to the build. Without them the Gmail option
explains that it isn't set up and the Mailgun API can be used instead.

## 1. Google Cloud project

1. https://console.cloud.google.com › create a project (e.g. "Messages++").
2. APIs & Services › Library › **Gmail API** › Enable.
3. APIs & Services › **OAuth consent screen** (Google Auth Platform):
   - User type **External**; app name "Messages++ by Comeriver"; support email; logo optional.
   - App domain: home page `https://messages.comeriver.com`, privacy policy `https://messages.comeriver.com/privacy`,
     terms `https://messages.comeriver.com/terms`; authorised domain `comeriver.com`.
   - Data access › Add scope `.../auth/gmail.send`.
   - Audience: while **Testing**, add up to 100 test users (their Gmail addresses). Only they can connect.

## 2. OAuth clients

Create these under APIs & Services › Credentials › Create credentials › OAuth client ID:

- **Web application** (no redirect URIs needed). Its client id is the *server client id* Android uses.
- **Android**: package `com.comeriver.messages` and the **SHA-1** of every key that signs the app:
  - debug (this Mac's key: `4D:F5:91:3A:8B:24:D2:77:2D:42:B6:3A:39:B7:2D:D5:9A:DC:CA:44`): `keytool -list -v -keystore ~/.android/debug.keystore -alias androiddebugkey -storepass android -keypass android`
  - upload key: `keytool -list -v -keystore <your upload .jks> -alias <alias>`
  - Play App Signing key: Play Console › Protected with Play › Play app signing › App signing key certificate ›
    SHA-1 (this app: `0A:64:C2:9C:CF:28:28:05:47:C4:05:E4:91:BD:7E:26:5B:A4:C0:6C`).
  (One Android client per SHA-1.)
- **iOS**: bundle id `com.comeriver.messages`. Note its client id and its **iOS URL scheme**
  (the reversed client id, `com.googleusercontent.apps.…`).

## 3. Build with the client ids

The ids live in `lib/app/google_config.dart` (project `comeriver-messages`; the Android client is
`194874520779-dphp2os3…`, the Web client `194874520779-3a70p7hi…`). The Web client id is already the default, so
Android needs nothing extra at build time. The Web client's secret is not used by the app; never add it. To
override per build:

```
flutter build appbundle \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id>.apps.googleusercontent.com \
  --dart-define=GOOGLE_IOS_CLIENT_ID=<ios client id>.apps.googleusercontent.com
```

Use the same `--dart-define`s with `flutter run` while testing.

**iOS only:** add the reversed client id as a URL scheme in `ios/Runner/Info.plist`:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>com.googleusercontent.apps.YOUR-IOS-CLIENT-ID</string></array>
  </dict>
</array>
```

## 4. Connect in the app

Settings › Email › Gmail › **Connect Gmail** › choose the account › allow "Send email on your behalf".
Then **Send test email**.

## 5. Before publishing: Google verification

`gmail.send` is a **sensitive** scope. To leave Testing (more than 100 users), submit the consent screen for
verification: privacy policy URL, the scope justification below and a short video of connecting Gmail and
sending a test email. No paid security assessment is needed for send-only.

> Justification: "Users send email campaigns they wrote to contacts they chose. The app sends each email through
> the user's own Gmail with gmail.send only; it never reads, stores or forwards the user's mail."

## Limits and behaviour

- Personal Gmail allows about 500 recipients a day (Workspace more). Keep Settings › Email limits under that.
- Access tokens are refreshed without asking while Google allows it. If a scheduled campaign runs in the
  background and Google needs the user to sign in again, the emails wait and a notification says so: open the
  app, reconnect Gmail, then tap Send on the campaign.
- Disconnect removes the app's Gmail access (also revocable at https://myaccount.google.com/permissions).
