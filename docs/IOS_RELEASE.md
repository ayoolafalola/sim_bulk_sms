# Releasing Messages++ on the App Store (iPhone and iPad)

## 1. Before you start
- **Apple Developer Program**, enrolled as an organisation (Comeriver Limited, needs a D-U-N-S number).
- Xcode › open `ios/Runner.xcworkspace` › **Runner** target › **Signing & Capabilities**:
  - Team: Comeriver Limited · "Automatically manage signing" on · Bundle ID `com.comeriver.messages`.
  - **+ Capability › In-App Purchase** (for Comeriver Pro).
- Already in the project: app icons (all sizes), display name Messages++, iPhone **and iPad**, iOS 15+,
  Gmail sign-in (iOS client id + URL scheme), privacy manifest (`ios/Runner/PrivacyInfo.xcprivacy`) and the
  export-compliance answer (`ITSAppUsesNonExemptEncryption = NO`: only standard HTTPS).

## 2. Build and upload
The version comes from `pubspec.yaml` (`tool/release_android.sh --bump-only` bumps it for both stores).

```
flutter build ipa --release --obfuscate --split-debug-info=build/ios-debug-info
```

Then open `build/ios/archive/Runner.xcarchive` in Xcode (or use the Transporter app with
`build/ios/ipa/*.ipa`) › **Distribute App › App Store Connect › Upload**. Test it in **TestFlight** first.

## 3. App Store Connect › the app

| Field | Value |
| --- | --- |
| Name (23/30) | `Messages++ by Comeriver` |
| Subtitle (29/30) | `Group texts & email campaigns` |
| Primary / secondary category | Productivity / Business |
| Keywords (96/100) | `bulk sms,group text,mass text,broadcast,church,campaign,mailgun,email,schedule,reminder,contacts` |
| Support URL | https://messages.comeriver.com |
| Marketing URL | https://messages.comeriver.com |
| Privacy Policy URL | https://messages.comeriver.com/privacy |
| Copyright | 2026 Comeriver Limited |
| Age rating | 4+ (no objectionable content; answer "No" throughout) |

### Description (1833/4000)

```
Messages++ lets you send personalised messages to whole groups of your contacts, by text or by email, now or on a schedule. Texts go from your own number through Messages; emails go out by themselves through your own email service. No account, no server, no per-message fees.

YOUR CONTACTS, ALREADY HERE
• Use your contacts directly: numbers, emails, birthdays and companies.
• Long-press to pick people and add them to groups: a choir, a class, your customers, your team.
• Import more contacts from a CSV or Excel export.

REACH YOUR PEOPLE
• Send by text, by email, or both. Emails go through your Mailgun-compatible service or your Gmail.
• Write once and personalise with {first_name}, {company}, {birthday} and more.
• Preview the exact message each person gets, and see how many SMS parts it uses.
• Texts open in Messages for you to review and tap Send, one person at a time or up to 20 at once.

ON YOUR SCHEDULE
• Send once at a set time, or every week on the days you choose.
• A reminder arrives when a scheduled campaign is due; its emails go out on their own.

SEND SAFELY
• People who opt out are always left out.
• Follow every message: waiting, sent or failed, and send again to anyone who was missed.

FREE, OR COMERIVER PRO
• Free: every feature, with "Sent via messages.comeriver.com" at the end of campaign messages, up to 5 saved campaigns, 1 schedule and 50 emails a day.
• Comeriver Pro (monthly or yearly subscription): unlimited campaigns and schedules, automatic birthday wishes, your own email limits, and your own signature or none.

PRIVATE BY DESIGN
Your contacts and messages stay on your device. Messages++ has no account and no server, and shows no ads.

Please only message people who have agreed to hear from you. Your carrier's normal SMS charges apply.

Messages++ is made by Comeriver Limited.
```

### Screenshots
- **iPhone 6.9"** (1320×2868): `assets/store/ios/iphone_1.png` … `iphone_7.png`
- **iPad 13"** (2064×2752): `assets/store/ios/ipad_1.png` … `ipad_7.png`

Regenerate with `python3 tool/make_screenshots.py`. They show what the iPhone app really does (no inbox, a tap per
text, reminders); keep them in step with the app.

## 4. App Privacy ("nutrition label")
**Data used to track you:** none. **Data linked to you:** none. **Data not linked to you:**
- Contact Info › **Name**, **Email Address**: App Functionality.
- User Content › **Emails or Text Messages**: App Functionality.

(Only campaign emails leave the device, to the email service the user chose. Texts go through Messages; contacts
stay on the device.) This matches `PrivacyInfo.xcprivacy`.

## 5. Comeriver Pro on the App Store
1. **Agreements, Tax and Banking:** accept the **Paid Apps** agreement, add bank and tax details.
2. App › **Subscriptions** › group **Comeriver Pro** › two auto-renewable subscriptions:
   - `comeriver_pro_monthly`: 1 month · `comeriver_pro_yearly`: 1 year. No introductory offer (no trial).
   - Display name, description ("Unlimited campaigns and schedules, your own email limits and signature."),
     prices, and the review screenshot (`assets/store/ios/iphone_7.png`).
3. Submit the subscriptions **with the first app version** (App Store › version page › In-App Purchases and
   Subscriptions › select both).
4. Test in TestFlight (sandbox purchases are free).

## 6. App Review notes (App Review Information › Notes)

```
No account or login is needed.

Messages++ helps people send personalised messages to groups of their contacts. On iPhone and iPad, texts are always sent by the user: each text (or a batch of up to 20 recipients) opens in Apple's Messages composer, where the user reviews it and taps Send. The app never sends texts by itself. Emails are sent through the user's own email service.

To try it: Contacts tab › Groups › New group, add yourself. Campaigns › New campaign › Send by "Text (SMS)", message "Hello {first_name}", choose the group › Save and review › Open next message › tap Send in the composer.

Scheduling: on a campaign, Schedule… › choose a time 2 minutes ahead › Save (allow notifications). A reminder appears at that time; tapping it opens the campaign ready to send.

"Connect Gmail" (Settings › Email) uses Google sign-in only to authorise sending email from the user's own Gmail account (gmail.send scope). It is not used to sign in to the app, which has no accounts.

Comeriver Pro (Settings › Comeriver Pro) is optional; the free app is fully usable. Pro removes the "Sent via messages.comeriver.com" line from campaign messages and lifts the free limits.
```

## 7. Review risks
- **Name:** Apple's own app is "Messages". "Messages++ by Comeriver" helps; if Apple asks for a change, keep the
  icon and use a backup name (e.g. "Comeriver Messages++").
- **Expectations:** the listing says texts need a tap in Messages; keep it that way.
