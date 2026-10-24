# Google Play store listing

Paste these into Play Console › Grow users › Store presence › **Main store listing**. Play shows the description as
plain text, so headings are in capitals and bullets are "•".

| Field | Value |
| --- | --- |
| App name (23/30) | `Messages++ by Comeriver` |
| Short description (70/80) | `Your texts, plus personalised messages to your groups by SMS or email.` |
| App icon (512×512) | `assets/icon/play_store_512.png` |
| Feature graphic (1024×500) | `assets/icon/play_feature_graphic.png` (source: `assets/icon/src/feature_graphic.svg`) |
| Category | Communication |
| Tags | Messaging, SMS (pick the closest Play offers) |
| Contact email | messages@comeriver.com |
| Website | https://messages.comeriver.com |
| Privacy policy (App content) | https://messages.comeriver.com/privacy |
| Contains ads | No |
| In-app purchases | Yes (Comeriver Pro subscription) |

Name on the phone: **Messages++**.

## Full description (2403/4000)

```
Messages++ is your everyday messaging app with a superpower: send personalised messages to whole groups of your contacts, by text from your own SIM or by email, right now or on a schedule. Texts come from your own number and are billed by your carrier as normal SMS. No account, no server, no per-message fees.

YOUR MESSAGES
• All your conversations in one place, with notifications you can reply to and mark as read.
• Start new messages, reply to declined calls with a text, and use either SIM on dual-SIM phones.
• Campaign messages appear in each person's conversation, labelled with the campaign.

YOUR CONTACTS, ALREADY HERE
• Use your phone's contacts directly: numbers, emails, birthdays and companies, always in sync.
• Long-press to pick people and add them to groups: a choir, a class, your customers, your team.
• Import more contacts from a CSV or Excel export.

REACH YOUR PEOPLE
• Send by text, by email, or both. Emails go through your Mailgun-compatible service or your Gmail.
• Write once and personalise with {first_name}, {company}, {birthday} and more.
• Preview the exact message each person gets, and see how many SMS parts it uses before you send.

ON YOUR SCHEDULE
• Send once at a set time, or every week on the days you choose (for example Sundays at 8:00).
• Scheduled campaigns send by themselves, even with the app closed.
• Send again to the same people, or to everyone in your groups now.

SEND SAFELY
• Set a pause between texts and hourly and daily limits, so your SIM stays in good standing.
• People who opt out are always left out.
• Follow every message: sending, sent, delivered (when your carrier reports it) or failed, and retry the failed ones.

FREE, OR COMERIVER PRO
• Free: every feature, with "Sent via messages.comeriver.com" at the end of campaign messages, up to 5 saved campaigns, 1 schedule and 50 emails a day.
• Comeriver Pro (monthly or yearly subscription): unlimited campaigns and schedules, your own email limits, and your own signature or none.
• Personal messages never carry a signature.

PRIVATE BY DESIGN
Your contacts and messages stay on your phone. Messages++ has no account and no server, and shows no ads.

Please only message people who have agreed to hear from you. Standard SMS charges from your carrier apply. Picture messages (MMS) are not supported yet.

Messages++ is made by Comeriver Limited and is not affiliated with Google.
```

## Phone screenshots

Upload `assets/store/screenshot_1.png` … `screenshot_8.png` (1080×1920, in this order). Each is a caption on the brand
gradient above a phone showing that app screen, drawn in the app's own design with demo data (no real people).
Regenerate with `python3 tool/make_screenshots.py` (edit the captions and screens in that file).

1. All your texts, plus so much more: Messages tab.
2. Every campaign reply, right in the chat: a conversation with a campaign message.
3. Write once. Personalise for all: campaign editor with preview and SMS counter.
4. Follow every message, live: a campaign sending, SMS and email counts.
5. Your phone's contacts, already here: Contacts › Groups.
6. Send on your schedule: weekly schedule.
7. Text or email. Or both: Settings › Email (Mailgun API).
8. Free to start. Pro when you grow: Comeriver Pro.

Play requires screenshots to show the app accurately: if a screen changes before launch, update its mockup.
