# Play Console declarations (full build)

Fill these in Play Console › Policy and programs › App content. Policy text changes; re-read the linked
policies before submitting. Be accurate: misleading declarations can lead to removal or account suspension.

> **Known risk: picture messages (MMS).** The app receives MMS as Android requires (`WAP_PUSH_DELIVER`), but
> doesn't download them yet: it notifies the user that a picture message arrived and suggests their previous
> messaging app (docs/KNOWN_LIMITATIONS.md). Some text-only SMS apps are on Play, but a reviewer may still ask
> for full MMS support. If the declaration is refused for this, build Part C and resubmit; the store build
> (docs/RELEASE.md) is the fallback that needs no SMS permissions.

## 1. SMS and Call Log permissions — Permissions Declaration Form

Policy: https://support.google.com/googleplay/android-developer/answer/10208820

- **Permissions:** `SEND_SMS`, `READ_SMS`, `RECEIVE_SMS`, `RECEIVE_MMS`, `RECEIVE_WAP_PUSH`, `WRITE_SMS`.
  No Call Log permissions.
- **Core functionality:** **Default SMS handler.**
- **How the app qualifies:** it implements everything Android requires of a default messaging app
  (`SMS_DELIVER` and `WAP_PUSH_DELIVER` receivers, a compose screen for `SENDTO`, the `RESPOND_VIA_MESSAGE`
  quick-reply service), asks the user to make it the default messaging app (RoleManager `ROLE_SMS`), and while it
  is the default it stores every incoming and outgoing text in the phone's message store.
- **When it isn't the default** (the user declined or later chose another app), it does not use the SMS
  permissions: campaigns open the user's Messages app one message at a time instead, and email still works.
- **Description (draft):**
  "Comeriver Messages is a messaging app: users read and reply to their SMS conversations, get notifications for
  incoming texts with Reply and Mark as read, start new messages, and reply to declined calls with a text. It
  also lets them send their own personalised messages to groups of their contacts, now or on a schedule, from
  their own SIM, with delays and hourly/daily limits they set; those messages appear in each person's
  conversation. SMS permissions are used only while the app is the user's default SMS app. Messages are never
  uploaded; the app has no server."
- **Video (60–90 s, screen recording):**
  1. Fresh install › setup › "Make Comeriver Messages your default messaging app" › Android's prompt › Yes.
  2. Receive a text from a second phone: notification › Reply from the notification.
  3. Messages tab › open the conversation › reply.
  4. Campaigns › a ready campaign to 2 numbers › Send › show both messages in their conversations.
  5. Settings › Apps › Default apps › SMS: switch back to the old app; open Comeriver Messages: the Messages tab
     offers to become the default again and campaigns use the Messages app.

## 2. Foreground service (special use) — Foreground service permissions declaration

- **Type:** `specialUse` · subtype in the manifest: "Sends SMS campaigns that the user started or scheduled,
  through the user's own SIM".
- **Why no standard type fits:** sending a user-started batch of texts and emails with pauses between messages is
  not media, location, data sync or a phone call; it may take minutes to hours because of the user's send limits.
- **User impact if deferred/stopped:** the user's messages go out late or not at all.
- **Video:** step 4 above, plus: tap Send, press Home, show the "Sending…" notification and messages continuing;
  then schedule a campaign 2 minutes ahead, swipe the app away, show it sending at that time.

## 3. Exact alarms

The app uses `SCHEDULE_EXACT_ALARM` (granted by the user under Alarms & reminders), not `USE_EXACT_ALARM`.
Justification if asked: "Starts the user's scheduled campaigns at the time the user chose, and resumes a
campaign paused by the user's own hourly/daily limit."

## 4. Battery optimisation exemption (`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`)

Play restricts this permission to apps whose core function is broken by battery optimisation. Justification:
"Scheduled campaigns must start at the user-chosen time with the screen off; on many phones battery
optimisation delays or cancels them." **Risk:** if this is questioned, removing it from the full build is a
one-line change (the setup screen then opens the general battery settings list instead).

## 5. Contacts (`READ_CONTACTS`)

Not a restricted permission. Asked only after the user taps "Use phone contacts". The app then keeps a read-only
copy of the phone's contacts (names, numbers, emails, birthdays, company, address, notes) in its database on the
phone so they can be messaged and grouped. Nothing is uploaded. Edits happen in the phone's Contacts app.

## 6. Gmail (only if you ship Gmail sending)

The Google OAuth consent screen and its verification are separate from Play (docs/GMAIL_SETUP.md). In Play,
nothing extra is declared: the app has no server and the email goes straight from the phone to Gmail.

## 7. Other App content items

- **Privacy policy:** https://messages.comeriver.com/privacy
- **Ads:** No ads. **App access:** All functionality available without special access (no login).
- **Content rating:** communication app; users exchange messages with people they choose (answer "Yes" to
  users interacting/communicating), no public user-generated content, no location sharing.
- **Target audience:** 18+ (people and organisations messaging their own contacts).
- **Data safety:** see data_safety.md.
