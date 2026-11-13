# Releasing Messages++ on the App Store (iPhone and iPad)

App Store Connect record: **Messages++ Bulk SMS & Messages** (Apple ID 6833393807), bundle `com.comeriver.messages`,
team Comeriver Limited (`9S84UDUKSQ`). The listing text lives in `tool/asc_listing.py`; this page covers what a
person must do and why.

## 1. One-time setup
1. **Signing & capabilities** (Xcode › Runner and ShareExtension targets › Signing & Capabilities, team Comeriver):
   Push Notifications, Associated Domains
   (`applinks:messages.comeriver.com`, `applinks:contacts.comeriver.com`) and In-App Purchase (Runner). The
   entitlements files are already in the project; `tool/release_ios.sh` signs automatically with the API key,
   which normally turns these on for the App IDs. No App Group is needed: the Share Extension hands the
   shared text to the app inside the link it opens. If an archive fails on a capability, enable it once in the
   Apple Developer portal for `com.comeriver.messages` and `com.comeriver.messages.ShareExtension`.
2. **Share Extension target**: `ruby ios/tool/configure_native_integration.rb` (already run; safe to run again).
3. **Release settings**: copy `config/production.example.json` to `config/production.json` and fill in the
   Messages++ Firebase app. Register the iOS app `com.comeriver.messages` (and Android `com.comeriver.messages`)
   in the **same Firebase project Contacts++ uses**, so the Contacts++ server can push to it; upload the APNs key
   to that Firebase iOS app. Without it, chats and web sends arrive only while the app is open.
4. **Universal Links**: `contacts.comeriver.com/.well-known/apple-app-site-association` already lists
   `9S84UDUKSQ.com.comeriver.messages` for `/messages/*`. Add an AASA file to messages.comeriver.com when app links
   on that domain are wanted.
5. **Paid Apps agreement** and the **Comeriver Pro** subscriptions (§5).

## 2. Build, upload and fill the listing
```
tool/release_ios.sh --bump --listing
```
Bumps the build number, builds and signs, uploads to TestFlight, waits for processing, then runs
`tool/asc_listing.py` (subtitle, description, keywords, categories Productivity/Business, age rating, review notes,
free price, all territories, screenshots from `assets/store/ios/`, and the build). Set `ASC_CONTACT_PHONE` (Apple
needs a phone for the reviewer) and `ASC_DEMO_CODE` (the Contacts++ review number's fixed code) in the environment.
The listing alone can be refreshed any time with `python3 tool/asc_listing.py`.

`tool/release.sh` releases everything (Play bundle, App Store, website) with one bump.

## 3. Listing summary
| Field | Value |
| --- | --- |
| Name | Messages++ Bulk SMS & Messages (set in App Store Connect) |
| Subtitle | Group texts, chats & email |
| Categories | Productivity / Business |
| Age rating | 4+ (messaging between people who accept each other's messages; no public content) |
| Support / marketing URL | https://messages.comeriver.com |
| Privacy policy | https://messages.comeriver.com/privacy |

The developer API is a web-only feature and is never mentioned in the app or the listing.

## 4. App Privacy ("nutrition label")
Set in App Store Connect › App Privacy (the API can't). **Tracking:** none. **Data linked to the user** (only with
the optional Contacts++ account), all for **App Functionality**:
- Contact Info › **Name**, **Phone Number**, **Email Address** (account; campaign emails to the user's email service)
- Identifiers › **User ID** (Contacts++ account), **Device ID** (push token)
- Contacts › **Contacts** (Backup and sync, when turned on)
- User Content › **Emails or Text Messages** (Contacts++ chats; backed-up texts and campaigns)

Without an account, only campaign emails leave the device. This matches `ios/Runner/PrivacyInfo.xcprivacy`.

## 5. Comeriver Pro on the App Store
1. **Agreements, Tax and Banking:** accept the **Paid Apps** agreement, add bank and tax details.
2. App › **Subscriptions** › group **Comeriver Pro** › two auto-renewable subscriptions:
   `comeriver_pro_monthly` (1 month) and `comeriver_pro_yearly` (1 year), no introductory offer. Display name,
   description ("Unlimited campaigns and schedules, your own email limits and signature."), prices, and the review
   screenshot (`assets/store/ios/iphone_7.png`).
3. Submit both subscriptions **with the first app version** (version page › In-App Purchases and Subscriptions).
4. Test in TestFlight (sandbox purchases are free).

## 6. Submitting
App Store Connect › Messages++ › iOS 1.0.1 › check the build, App Privacy and subscriptions › **Add for Review** ›
**Submit**. Review notes (in `tool/asc_listing.py`) explain: no account needed; texts always need a tap in
Messages; the optional Contacts++ account (review number +234 803 000 0000, code in the Password field), account
deletion, Gmail's send-only scope, Pro, and the share sheet and Siri shortcuts.

## 7. Review risks
- **Name:** Apple's own app is "Messages". If Apple asks for a change, keep the icon and use "Comeriver Messages++".
- **Sign in with Apple:** not required: the only login is the company's own account system (Contacts++), and it
  is optional (guideline 4.8 exception).
- **Account deletion (5.1.1(v)):** Settings › Contacts++ account › Delete account opens Contacts++ account deletion.
- **Expectations:** the listing says texts need a tap in Messages; keep it that way.
- **Screenshots** show the free texting flow; regenerate with `python3 tool/make_screenshots.py` when adding chat
  and backup screens.
