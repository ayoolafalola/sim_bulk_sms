# Default messaging app: phone test checklist (Parts B1 + B2)

Keep your previous messaging app installed; you can switch back anytime (Settings › Apps › Default apps › SMS app).
Your old texts are not touched by switching.

1. Open the app › Messages tab › **Make default messaging app** › choose Messages++. The tab now lists
   your existing conversations with names and unread counts.
2. **Receive with the app closed:** swipe the app away, text yourself from another phone. A notification appears;
   tap it — that conversation opens. Then open your old messaging app: the text is there too (same store).
3. **Reply** in the conversation and with a quick-reply chip. Status goes Sending → Sent (→ Delivered if your
   carrier reports it). Turn on airplane mode and send: it shows "Not sent · tap to try again".
4. **Decline a call with "Reply with message"**: the text is sent and appears in that conversation.
5. **From another app:** Contacts app › a contact › message icon. This app opens that conversation.
6. **Campaign:** send a campaign to two of your numbers: each message appears in that person's conversation.
7. **Switch back** to your old messaging app as default. In this app: the Messages tab offers to become default
   again, and campaigns use the Messages-app flow. Nothing in your old app is lost.
8. **Picture message (not supported yet):** an incoming MMS only shows a notice in this app.
9. **Reply from the notification** (app closed): pull down the notification, Reply, type, send. It appears in the
   conversation; Mark as read clears the unread count.
10. **New message** to two people (one saved contact, one typed number): each gets their own text.
11. **Campaign label:** after a campaign, its text in a person's conversation shows "Campaign · <name>"; tap it.
12. **Long-press** a message › Delete › Undo; then delete for real. Long-press a conversation › Delete conversation.
13. **Dual SIM:** the SIM chip shows the SIM they texted you on; switch it and send.
14. **Header menu:** Add to contacts, Add to group… from a conversation with an unsaved number.

**Contacts sync (Part D1)**

15. **Contacts tab**: "Use your phone's contacts?" › Use phone contacts › allow. Your phone contacts appear.
16. **Change on the phone**: in the Contacts app add a number or birthday to someone, return to this app: it shows within seconds.
    Delete a test contact in the Contacts app: it disappears here.
17. **Contact screen**: tap someone with two numbers › tap the other number: it becomes "Used for texts". Edit opens the Contacts app.
18. **Select**: long-press a contact › Select all › Add to group › New group. Open the group: everyone is there.
19. **Placeholders**: a campaign with "Hi {first_name}, greetings to all at {company}" previews with each person's company filled in.
20. **Settings › Contacts**: count and last sync; turn sync off, then on again.

**Email (Part D2)**

21. **Settings › Email › Mailgun API**: base URL, domain, API key, From address › Save › Send test email to yourself.
22. **Campaign by email**: Send by "Email", subject "Hi {first_name}", a group with emails › Save › Send. Check the
    inbox; the campaign shows "Email · Sent".
23. **Text and email**: Send by "Text and email" to someone with both: one text and one email, counted separately.
24. **Wrong API key**: change one letter, send an email campaign: it pauses after the first email ("Failed: check
    the API key"). Fix it and Resume.
25. **Not default / iPhone**: switch back to your old messaging app, send a "Text and email" campaign: the emails
    go first, then the texts open in your Messages app one by one.
26. **Gmail** (only with a build that has the Google client ids): Settings › Email › Gmail › Connect › Send test email.

**Free app and Comeriver Pro**

27. **Signature:** a new campaign's preview ends with "Sent via messages.comeriver.com"; the counter says
    "signature included". Send it: the text arrives with that line. Reply from the Messages tab: no line.
28. **Limits:** save 5 campaigns, then a 6th: "See Pro". Add a schedule to a second campaign: "See Pro".
29. **Buy (needs the internal-testing build from Google Play and a license tester, docs/BILLING_SETUP.md):**
    Settings › Comeriver Pro › Monthly › test card › "Pro is on". Turn on a signature "Test", send a campaign: it
    ends with "Test". Turn it off: no line.
30. **Cancel:** Manage subscription › cancel; after the test renewal period, reopen the app: Free again.
31. **Restore:** clear the app's data (or reinstall), Settings › Comeriver Pro › Restore purchases: Pro again.

**Launch prep (Messages++)**

32. **Name and icon:** the home screen shows the new two-bubble icon named "Messages++". With themed icons on
    (Android 13+: Wallpaper & style › Themed icons) it turns one-colour. Notifications show the bubble icon in green.
33. **No flashing:** send a campaign to a few numbers and watch its screen: the numbers and bar update smoothly,
    with no spinner flashing.
34. **20 at once:** switch to your old messaging app as default, make a campaign without placeholders to 3 of your
    numbers, tap Send › "20 at once": your Messages app opens with all 3 numbers. Send, come back, "Sent".
    Check whether your Messages app made it a group chat (depends on its settings).

**Settings › About, Reset, notifications**

35. **Fresh install (or Reset app):** the first setup step is **Notifications**: allow it, then make Messages++ the
    default. Later switch the default back to your old app: Notifications still show as on.
36. **Messages category off:** Android Settings › Apps › Messages++ › Notifications › turn off "Messages". Back in the
    app, App setup shows "Message notifications are turned off" with Open settings.
37. **About:** Share opens the share sheet; Website, Privacy, Terms and Comeriver open in the browser; Contact support
    opens your email app to messages@comeriver.com with the version filled in.
38. **Reset app…:** bottom of Settings › type RESET › Reset: the welcome screen appears; campaigns and groups are gone;
    your texts are still in the Messages tab once it's default again; Pro is still active.

**iPhone / iPad (TestFlight or Xcode)**

39. Settings has no "App setup"; nothing mentions Android or Google Play (Pro says "cancel in the App Store").
40. Settings › Email › Gmail › Connect Gmail › Send test email.
41. A same-text campaign to 3 of your numbers › Send › "20 at once": one Messages composer with all 3 › Send.
    The campaign shows them as Sent. Cancel the composer instead: they stay Waiting/Cancelled to try again.
42. Schedule a campaign 2 minutes ahead › allow notifications › close the app: a reminder appears; tap it: the
    campaign opens ready to send.
43. iPad: the app is centred with margins on a 13" iPad, full width on smaller ones; rotate to landscape.

**Birthdays and email-only import**

44. Add contact: set a Birthday (day and month, no year) › save › the contact screen shows it.
45. Import a CSV with Name, Email, Birthday columns (no phone): rows import as email-only contacts with birthdays;
    the summary shows "N email-only" and how many birthdays were read.
46. Campaigns › Birthday wishes: without Pro the switch offers Pro. With Pro (or Pretend Pro): turn on, set the time
    2 minutes ahead, give a test contact today's birthday › at that time a "Birthday wishes · <date>" campaign is sent
    (Android) or a reminder appears (iPhone). Changing the time back doesn't send a second one today.

If anything misbehaves: `adb logcat -s SimBulkSms flutter` while reproducing, and note the step.
